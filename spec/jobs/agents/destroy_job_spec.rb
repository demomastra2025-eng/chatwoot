require 'rails_helper'

RSpec.describe Agents::DestroyJob do
  subject(:job) { described_class.perform_later(account, user) }

  let!(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:team1) { create(:team, account: account) }
  let!(:inbox) { create(:inbox, account: account) }
  let!(:owned_contact) { create(:contact, account: account, owner: user) }

  before do
    create(:team_member, team: team1, user: user)
    create(:inbox_member, inbox: inbox, user: user)
    create(:conversation, account: account, assignee: user, inbox: inbox)
  end

  it 'enqueues the job' do
    expect { job }.to have_enqueued_job(described_class)
      .with(account, user)
      .on_queue('low')
  end

  describe '#perform' do
    it 'removes inboxes, teams, conversations, and contact ownership when removed from account' do
      AccountUser.find_by!(account: account, user: user).delete
      described_class.perform_now(account, user)

      user.reload
      expect(user.teams.length).to eq 0
      expect(user.inboxes.length).to eq 0
      expect(user.notification_settings.length).to eq 0
      expect(user.assigned_conversations.where(account: account).length).to eq 0
      expect(owned_contact.reload.owner_id).to be_nil
    end

    it 'transfers contacts, deals, tasks, and conversations to the selected replacement employee' do
      replacement = create(:user, account: account)
      deal = create(:crm_deal, account: account, owner: user)
      task = create(:crm_task, account: account, assignee: user)
      conversation = user.assigned_conversations.where(account: account).first

      AccountUser.find_by!(account: account, user: user).delete
      described_class.perform_now(account, user, replacement.id)

      expect(owned_contact.reload.owner_id).to eq(replacement.id)
      expect(deal.reload.owner_id).to eq(replacement.id)
      expect(task.reload.assignee_id).to eq(replacement.id)
      expect(conversation.reload.assignee_id).to eq(replacement.id)
    end

    it 'does not remove restored memberships when the account user is active again' do
      described_class.perform_now(account, user)

      user.reload
      expect(user.teams).to include(team1)
      expect(user.inboxes).to include(inbox)
      expect(user.notification_settings.exists?(account_id: account.id)).to be(true)
      expect(user.assigned_conversations.where(account: account).count).to eq(1)
      expect(owned_contact.reload.owner_id).to eq(user.id)
    end
  end
end
