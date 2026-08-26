require 'rails_helper'

RSpec.describe Reminders::CaptainGeneratedMessageService do
  describe '#perform' do
    it 'uses a temporary assistant clone for generation but returns the persisted assistant as message sender' do
      account = create(:account)
      conversation = create(:conversation, account: account)
      assistant = create(
        :captain_assistant,
        account: account,
        description: 'Base assistant instructions',
        config: { 'feature_document_reading' => true }
      )
      reminder = create(
        :reminder,
        account: account,
        conversation: conversation,
        remindable: conversation,
        text_mode: :agent,
        instructions: 'Write a short follow-up',
        metadata: { 'captain_assistant_id' => assistant.id }
      )
      runner = instance_double(
        Captain::Assistant::AgentRunnerService,
        generate_response: { response: 'Generated follow-up', captain_trace: { 'steps' => [] } }
      )
      history_message = create(:message, conversation: conversation, account: account, content: 'History')
      allow(Captain::OpenAiMessageBuilderService).to receive(:new).and_call_original

      expect(Captain::Assistant::AgentRunnerService).to receive(:new) do |**kwargs|
        generation_assistant = kwargs.fetch(:assistant)
        expect(generation_assistant).not_to be_persisted
        expect(generation_assistant.description).to include('Write a short follow-up')
        expect(kwargs.fetch(:source)).to eq('touch_agent')
        runner
      end

      expect do
        result = described_class.new(reminder: reminder, conversation: conversation).perform

        expect(result[:assistant]).to eq(assistant)
        expect(result[:assistant]).to be_persisted
      end.not_to change(Captain::Assistant, :count)
      expect(Captain::OpenAiMessageBuilderService).to have_received(:new).with(
        message: history_message,
        assistant: have_attributes(config: include('feature_document_reading' => true))
      )
    end
  end
end
