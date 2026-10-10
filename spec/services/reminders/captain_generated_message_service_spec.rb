require 'rails_helper'

RSpec.describe Reminders::CaptainGeneratedMessageService do
  describe '#perform' do
    it 'passes an exact deal event to the runner for scheduled AI messages' do
      account = create(:account)
      conversation = create(:conversation, account: account)
      assistant = create(:captain_assistant, account: account)
      deal = create(:crm_deal, account: account, originating_conversation: conversation)
      reminder = build(:reminder, account: account, remindable: deal, text_mode: :agent, instructions: 'Follow up',
                                  metadata: { 'captain_assistant_id' => assistant.id })
      runner = instance_double(Captain::Assistant::AgentRunnerService, generate_response: { response: 'Generated follow-up' })

      expect(Captain::Assistant::AgentRunnerService).to receive(:new).with(hash_including(deal: deal, conversation: conversation)).and_return(runner)

      expect(described_class.new(reminder: reminder, conversation: conversation).perform[:content]).to eq('Generated follow-up')
    end

    it 'uses a temporary assistant clone for generation but returns the persisted assistant as message sender' do
      account = create(:account)
      conversation = create(:conversation, account: account)
      assistant = create(:captain_assistant, account: account, description: 'Base assistant instructions')
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
    end
  end
end
