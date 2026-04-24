require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::ResolveConversationService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account, status: 'open') }
  let(:service) { described_class.new(assistant, user: user, conversation: conversation) }

  it 'returns a normalized payload with resolved status and optional reason' do
    payload = JSON.parse(service.execute(reason: 'Customer confirmed resolution'))

    expect(payload).to include(
      'action' => 'resolve_conversation',
      'conversation_id' => conversation.id,
      'conversation_display_id' => conversation.display_id,
      'status' => 'resolved',
      'reason' => 'Customer confirmed resolution'
    )
  end

  it 'returns a normalized payload without a reason when none is provided' do
    payload = JSON.parse(service.execute)

    expect(payload).to include(
      'action' => 'resolve_conversation',
      'conversation_id' => conversation.id,
      'conversation_display_id' => conversation.display_id,
      'status' => 'resolved'
    )
    expect(payload).not_to have_key('reason')
  end

  it 'returns an error output when auto-resolve is disabled for the account' do
    account.update!(captain_auto_resolve_mode: 'disabled')

    result = service.execute(reason: 'Customer confirmed resolution')

    expect(result).to eq('ERROR: ArgumentError: Auto-resolve is disabled for this account')
    expect(conversation.reload.status).to eq('open')
  end
end
