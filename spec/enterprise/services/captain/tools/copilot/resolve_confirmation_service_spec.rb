require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::ResolveConfirmationService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:service) { described_class.new(assistant, user: user, conversation: conversation) }
  let(:request) do
    create(
      :confirmation_request,
      account: account,
      conversation: conversation,
      contact: conversation.contact,
      inbox: conversation.inbox
    )
  end

  it 'resolves a confirmation request with a structured payload' do
    payload = JSON.parse(service.execute(
                           confirmation_request_id: request.id,
                           decision: 'confirmed',
                           source: 'manual',
                           confidence: 1.0,
                           metadata: { note: 'operator confirmed' }
                         ))

    expect(payload['action']).to eq('resolve_confirmation')
    expect(payload.dig('confirmation_request', 'status')).to eq('confirmed')
    expect(payload.dig('confirmation_request', 'resolution', 'source')).to eq('manual')
    expect(request.reload.resolution_metadata).to include('note' => 'operator confirmed')
  end

  it 'does not resolve requests from another account' do
    other_request = create(:confirmation_request)

    result = service.execute(confirmation_request_id: other_request.id, decision: 'confirmed', source: 'manual')

    expect(result).to start_with('ERROR: ActiveRecord::RecordNotFound')
    expect(other_request.reload).to be_pending
  end
end
