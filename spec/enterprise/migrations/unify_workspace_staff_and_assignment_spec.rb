require 'rails_helper'
require Rails.root.join('db/migrate/20261014100000_unify_workspace_staff_and_assignment')
require Rails.root.join('db/migrate/20261014101000_unify_captain_text_routing')

RSpec.describe UnifyWorkspaceStaffAndAssignment do
  let(:account) { create(:account) }

  it 'restores missing memberships and selects the inbox auto-assignment majority' do
    staff = create(:user, account: account)
    first = create(:inbox, account: account, enable_auto_assignment: false)
    second = create(:inbox, account: account, enable_auto_assignment: true)
    first.inbox_members.where(user: staff).delete_all

    described_class.new.up
    described_class.new.up

    expect(first.reload.members.ids).to include(staff.id)
    expect(second.reload.members.ids).to include(staff.id)
    expect(account.reload.conversation_auto_assignment_enabled?).to be(true)
    expect(first.inbox_members.where(user: staff).count).to eq(1)
  end

  it 'uses the off majority and applies the account linked assignment policy' do
    first = create(:inbox, account: account, enable_auto_assignment: false)
    create(:inbox, account: account, enable_auto_assignment: false)
    create(:inbox, account: account, enable_auto_assignment: true)
    policy = create(:assignment_policy, account: account)
    create(:inbox_assignment_policy, inbox: first, assignment_policy: policy)

    described_class.new.up

    expect(account.reload.conversation_auto_assignment_enabled?).to be(false)
    expect(account.workspace_assignment_policy).to eq(policy)
    expect(account.inboxes.last.effective_assignment_policy).to eq(policy)
  end

  it 'moves text links to the most used entry agent and only backfills switches once' do
    first = create(:captain_assistant, account: account)
    second = create(:captain_assistant, account: account)
    first_inbox = create(:inbox, account: account)
    second_inbox = create(:inbox, account: account)
    create(:captain_inbox, inbox: first_inbox, captain_assistant: first, ai_enabled: true)
    create(:captain_inbox, inbox: second_inbox, captain_assistant: second, ai_enabled: false)
    2.times do
      conversation = create(:conversation, account: account, inbox: second_inbox)
      create(:message, account: account, inbox: second_inbox, conversation: conversation,
                       sender: second, message_type: :outgoing)
    end

    UnifyCaptainTextRouting.new.up
    expect(account.reload.captain_default_assistant_id).to eq(second.id)
    expect(first_inbox.reload.captain_inbox.captain_assistant_id).to eq(second.id)
    expect(second_inbox.reload.captain_inbox).to be_ai_enabled

    # A rerun must not switch on a channel disabled after the backfill.
    second_inbox.captain_inbox.update!(ai_enabled: false)
    UnifyCaptainTextRouting.new.up
    expect(second_inbox.reload.captain_inbox).not_to be_ai_enabled
  end

  it 'preserves account settings when no active external agent exists' do
    account.update!(settings: account.settings.to_h.merge('workspace_timezone' => 'UTC'))

    UnifyCaptainTextRouting.new.up

    expect(account.reload.settings['workspace_timezone']).to eq('UTC')
    expect(account.captain_default_assistant_id).to be_nil
    expect(account.settings['captain_ai_routing_migrated']).to be(true)
  end
end
