require 'rails_helper'

RSpec.describe Captain::Tools::CancelResponseTool, type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:tool) { described_class.new(assistant) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }
  let(:run_context) { Captain::Runtime::RunContext.new({ state: { conversation: { id: conversation.id } } }) }
  let(:tool_context) { Captain::Runtime::ToolContext.new(run_context: run_context) }

  describe '#perform' do
    it 'stores pending response cancellation context and halts without creating messages' do
      expect do
        result = tool.perform(tool_context, reason: 'Acknowledgement does not need a reply')

        expect(result).to be_a(RubyLLM::Tool::Halt)
        expect(result.content).to eq('response_cancelled')
      end.not_to change(Message, :count)

      expect(run_context.context[:pending_response_cancellation]).to include(
        reason: 'Acknowledgement does not need a reply'
      )
    end

    it 'returns conversation not found when no current conversation is available' do
      missing_context = Struct.new(:state).new({ conversation: { id: 999_999 } })

      expect(tool.perform(missing_context)).to eq('Conversation not found')
    end
  end
end
