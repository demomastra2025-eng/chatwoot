require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::GetInboxSettingsService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account, name: 'Support AI') }
  let(:service) { described_class.new(assistant, user: user) }

  it 'returns account-scoped inbox settings, members, working hours, assignment, and Captain metadata' do
    inbox = create(:inbox, account: account, name: 'Support', timezone: 'Asia/Almaty')
    member = create(:user, account: account, name: 'Operator One')
    create(:inbox_member, inbox: inbox, user: member)
    policy = create(:assignment_policy, account: account, name: 'Support routing', assign_online_only: false)
    create(:inbox_assignment_policy, inbox: inbox, assignment_policy: policy)
    create(:captain_inbox, inbox: inbox, captain_assistant: assistant, auto_reply_mode: CaptainInbox::AUTO_REPLY_ALWAYS)
    create(:inbox, account: create(:account), name: 'Other')

    payload = JSON.parse(service.execute(inbox_id: inbox.id))

    expect(payload['action']).to eq('get_inbox_settings')
    expect(payload['inbox']).to include('id' => inbox.id, 'name' => 'Support', 'timezone' => 'Asia/Almaty')
    expect(payload['members']).to contain_exactly(include('id' => member.id, 'name' => 'Operator One'))
    expect(payload['working_hours'].size).to eq(7)
    expect(payload['assignment_policy']).to include('id' => policy.id, 'name' => 'Support routing', 'assign_online_only' => false)
    expect(payload['captain']).to include('enabled' => true, 'assistant_id' => assistant.id)
  end

  it 'rejects inboxes outside the assistant account' do
    other_inbox = create(:inbox, account: create(:account))

    result = service.execute(inbox_id: other_inbox.id)

    expect(result).to start_with('ERROR: ActiveRecord::RecordNotFound')
  end
end
