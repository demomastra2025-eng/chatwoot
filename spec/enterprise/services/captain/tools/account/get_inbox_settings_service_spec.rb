require 'rails_helper'

RSpec.describe Captain::Tools::Account::GetInboxSettingsService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let!(:assistant) { create(:captain_assistant, account: account, name: 'Support AI') }
  let(:service) { described_class.new(assistant, user: user) }

  it 'returns account-scoped inbox settings, members, working hours, assignment, and Captain metadata' do
    inbox = create(:inbox, account: account, name: 'Support', timezone: 'Asia/Almaty')
    member = create(:user, account: account, name: 'Operator One')
    create(:inbox_member, inbox: inbox, user: member)
    policy = create(:assignment_policy, account: account, name: 'Support routing', assign_online_only: false)
    create(:inbox_assignment_policy, inbox: inbox, assignment_policy: policy)
    account.update!(conversation_assignment_policy_id: policy.id)
    create(:captain_inbox, inbox: inbox, ai_enabled: true, auto_reply_mode: CaptainInbox::AUTO_REPLY_ALWAYS)
    create(:inbox, account: create(:account), name: 'Other')

    payload = JSON.parse(service.execute(inbox_id: inbox.id))

    expect(payload['action']).to eq('get_inbox_settings')
    expect(payload['inbox']).to include('id' => inbox.id, 'name' => 'Support', 'timezone' => 'Asia/Almaty')
    expect(payload['members']).to contain_exactly(
      include('id' => member.id, 'name' => 'Operator One'),
      include('id' => user.id)
    )
    expect(payload['working_hours'].size).to eq(7)
    expect(payload['assignment_policy']).to include('id' => policy.id, 'name' => 'Support routing', 'assign_online_only' => false)
    # A text channel names no agent: the AI picks one among the enabled agents of the workspace.
    expect(payload['captain']).to include('enabled' => true, 'ai_enabled' => true, 'auto_reply_mode' => CaptainInbox::AUTO_REPLY_ALWAYS)
    expect(payload['captain']).not_to include('assistant_id', 'assistant_name', 'voice_assistant_id')
  end

  it 'exposes the voice agent of a phone number, and only there' do
    voice_inbox = create_voice_inbox(account)
    create(:captain_inbox, inbox: voice_inbox, captain_assistant: assistant)

    payload = JSON.parse(service.execute(inbox_id: voice_inbox.id))

    expect(payload['captain']).to include('voice_assistant_id' => assistant.id, 'voice_assistant_name' => 'Support AI')
  end

  it 'rejects inboxes outside the assistant account' do
    other_inbox = create(:inbox, account: create(:account))

    result = service.execute(inbox_id: other_inbox.id)

    expect(result).to start_with('ERROR: ActiveRecord::RecordNotFound')
  end
end
