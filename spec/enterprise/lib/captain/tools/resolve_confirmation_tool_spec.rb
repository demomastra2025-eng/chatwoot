require 'rails_helper'

RSpec.describe Captain::Tools::ResolveConfirmationTool do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:request) do
    create(
      :confirmation_request,
      account: account,
      conversation: conversation,
      contact: conversation.contact,
      inbox: conversation.inbox
    )
  end
  let(:tool) { described_class.new(assistant) }
  let(:tool_context) { Struct.new(:state).new({ conversation: { id: conversation.id } }) }

  it 'resolves a request from the current account' do
    payload = JSON.parse(tool.perform(tool_context, confirmation_request_id: request.id, decision: 'confirmed', source: 'ai', confidence: 0.91))

    expect(payload['action']).to eq('resolve_confirmation')
    expect(payload.dig('confirmation_request', 'status')).to eq('confirmed')
    expect(request.reload.resolution_source).to eq('ai')
  end

  it 'rejects requests from another account' do
    other_request = create(:confirmation_request)

    result = tool.perform(tool_context, confirmation_request_id: other_request.id, decision: 'confirmed', source: 'ai')

    expect(result).to start_with('ERROR: ActiveRecord::RecordNotFound')
    expect(other_request.reload).to be_pending
  end
end
