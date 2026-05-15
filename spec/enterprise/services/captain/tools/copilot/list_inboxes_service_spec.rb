require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::ListInboxesService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account, name: 'Support AI') }
  let(:service) { described_class.new(assistant, user: user) }

  it 'returns account-scoped inbox metadata without cross-account inboxes' do
    inbox = create(:inbox, account: account, name: 'WhatsApp Sales', business_name: 'Sales')
    member = create(:user, account: account, name: 'Operator One')
    create(:inbox_member, inbox: inbox, user: member)
    policy = create(:assignment_policy, account: account, name: 'Sales routing')
    create(:inbox_assignment_policy, inbox: inbox, assignment_policy: policy)
    create(:captain_inbox, inbox: inbox, captain_assistant: assistant, auto_reply_mode: CaptainInbox::AUTO_REPLY_ALWAYS)
    create(:inbox, account: create(:account), name: 'Other account')

    payload = JSON.parse(service.execute(query: 'sales', include_members: true, limit: 10))

    expect(payload['total_count']).to eq(1)
    expect(payload['auto_reply_modes']).to match_array(CaptainInbox::AUTO_REPLY_MODES)
    expect(payload['inboxes'].size).to eq(1)
    expect(payload['inboxes'].first).to include(
      'id' => inbox.id,
      'name' => 'WhatsApp Sales',
      'business_name' => 'Sales',
      'enable_auto_assignment' => true,
      'working_hours_enabled' => false
    )
    expect(payload['inboxes'].first['assignment_policy']).to include(
      'id' => policy.id,
      'name' => 'Sales routing',
      'enabled' => true
    )
    expect(payload['inboxes'].first['captain']).to include(
      'enabled' => true,
      'assistant_id' => assistant.id,
      'assistant_name' => 'Support AI',
      'auto_reply_mode' => CaptainInbox::AUTO_REPLY_ALWAYS,
      'auto_reply_allowed_now' => true
    )
    expect(payload['inboxes'].first['members']).to contain_exactly(include('id' => member.id, 'name' => 'Operator One'))
  end

  it 'is active only for account administrators' do
    agent = create(:user, account: account)

    expect(service).to be_active
    expect(described_class.new(assistant, user: agent)).not_to be_active
  end
end
