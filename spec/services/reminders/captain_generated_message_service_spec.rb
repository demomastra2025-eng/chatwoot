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
        expect(result[:captain_trace]).to eq('steps' => [])
      end.not_to change(Captain::Assistant, :count)
    end

    describe 'the agent that writes the touch' do
      let(:account) { create(:account) }
      let(:conversation) { create(:conversation, account: account) }
      let!(:writer) { create(:captain_assistant, account: account) }
      let!(:colleague) { create(:captain_assistant, account: account) }
      let(:reminder) do
        build(:reminder, account: account, remindable: conversation, text_mode: :agent,
                         instructions: 'Follow up', metadata: { 'captain_assistant_id' => writer.id })
      end

      it 'is the agent stored with the touch, whichever other agents the workspace has' do
        runner = instance_double(Captain::Assistant::AgentRunnerService, generate_response: { response: 'Written by the stored agent' })
        allow(Captain::Assistant::AgentRunnerService).to receive(:new).and_return(runner)

        result = described_class.new(reminder: reminder, conversation: conversation).perform

        expect(result).to include(assistant: writer, content: 'Written by the stored agent')
      end

      it 'fails with agent_disabled when that agent is switched off, and no other agent writes the touch' do
        writer.update!(active: false)
        expect(Captain::Assistant::AgentRunnerService).not_to receive(:new)

        expect { described_class.new(reminder: reminder, conversation: conversation).perform }
          .to raise_error(ArgumentError, described_class::AGENT_DISABLED)
        expect(colleague.reload).to be_active
      end

      it 'fails with agent_disabled when that agent was deleted' do
        writer.destroy!
        expect(Captain::Assistant::AgentRunnerService).not_to receive(:new)

        expect { described_class.new(reminder: reminder, conversation: conversation).perform }
          .to raise_error(ArgumentError, described_class::AGENT_DISABLED)
      end

      it 'fails with agent_disabled when that agent is not an external agent any more' do
        writer.update!(usage_mode: 'internal_assistant')

        expect { described_class.new(reminder: reminder, conversation: conversation).perform }
          .to raise_error(ArgumentError, described_class::AGENT_DISABLED)
      end

      it 'does not choose a writer for a touch that names none: the writer is chosen when the touch is made' do
        reminder.metadata = {}
        expect(Captain::Assistant::AgentRunnerService).not_to receive(:new)

        expect { described_class.new(reminder: reminder, conversation: conversation).perform }
          .to raise_error(ArgumentError, 'Captain assistant is not configured for this touch')
      end
    end

    context 'when the runtime returns an undeliverable result' do
      let(:account) { create(:account) }
      let(:conversation) { create(:conversation, account: account) }
      let(:assistant) { create(:captain_assistant, account: account) }
      let(:reminder) do
        build(:reminder, account: account, remindable: conversation, text_mode: :agent,
                         instructions: 'Follow up', metadata: { 'captain_assistant_id' => assistant.id })
      end
      let(:runner) { instance_double(Captain::Assistant::AgentRunnerService) }

      before do
        allow(Captain::Assistant::AgentRunnerService).to receive(:new).and_return(runner)
      end

      {
        'a human handoff' => { response: ' conversation_handoff ' },
        'a provider error sentinel' => { response: 'conversation_handoff_due_to_provider_error' },
        'a cancellation sentinel' => { response: ' response_cancelled ' },
        'a cancelled response with otherwise nonblank content' => { 'response' => 'Cancelled follow-up', 'response_cancelled' => true },
        'an error with otherwise nonblank content' => { 'response' => 'Partial follow-up', 'error_class' => 'RubyLLM::RateLimitError' },
        'a moderation block with otherwise nonblank content' => { response: 'Blocked follow-up', moderation_blocked: true },
        'a suppressed response with otherwise nonblank content' => { 'response' => 'Suppressed follow-up', 'response_suppressed' => true }
      }.each do |outcome, payload|
        %i[touch wakeup].each do |mode|
          it "rejects #{outcome} in #{mode} mode" do
            allow(runner).to receive(:generate_response).and_return(payload)

            expect { described_class.new(reminder: reminder, conversation: conversation, mode: mode).perform }
              .to raise_error(ArgumentError, 'Captain did not produce a deliverable touch message')
          end
        end
      end
    end
  end
end
