require 'rails_helper'

RSpec.describe Crm::Tasks::ConversationReference do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:conversation) { create(:conversation, account: account) }
  let(:task) { create(:crm_task, account: account, originating_conversation: conversation) }
  let(:user_context) { { user: agent, account: account, account_user: agent.account_users.find_by!(account: account) } }

  before do
    InboxMember.where(user: agent, inbox: conversation.inbox).delete_all
  end

  def reference(record = task)
    described_class.new(task: record, user_context: user_context).perform
  end

  it 'returns separate database, display and account IDs for an inbox member' do
    conversation.update!(display_id: conversation.id + 100_000)
    create(:inbox_member, inbox: conversation.inbox, user: agent)

    expect(reference).to eq(id: conversation.id, display_id: conversation.display_id, account_id: account.id)
  end

  it 'uses canonical show access for a team member without inbox membership' do
    team = create(:team, account: account)
    create(:team_member, team: team, user: agent)
    conversation.update!(team: team)

    expect(reference).to include(display_id: conversation.display_id)
  end

  it 'does not disclose a reference without conversation access' do
    expect(reference).to be_nil
  end

  it 'does not disclose a cross-account task or origin' do
    foreign = create(:conversation)
    foreign_task = build_stubbed(:crm_task, account: foreign.account, originating_conversation: foreign)
    corrupt_task = build_stubbed(:crm_task, account: account, originating_conversation_id: foreign.id)

    expect(reference(foreign_task)).to be_nil
    expect(reference(corrupt_task)).to be_nil
  end

  it 'returns no reference for a missing or deleted association' do
    missing = build_stubbed(:crm_task, account: account, originating_conversation_id: nil)
    deleted = build_stubbed(:crm_task, account: account, originating_conversation_id: conversation.id)
    conversation.destroy!

    expect(reference(missing)).to be_nil
    expect(reference(deleted)).to be_nil
  end

  it 'honors the canonical custom-role restriction even with inbox access' do
    create(:inbox_member, inbox: conversation.inbox, user: agent)
    custom_role = create(:custom_role, account: account, permissions: ['crm_task_view'])
    user_context.fetch(:account_user).update!(custom_role: custom_role)

    expect(reference).to be_nil
  end
end
