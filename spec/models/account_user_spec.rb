# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AccountUser do
  include ActiveJob::TestHelper

  let!(:account_user) { create(:account_user) }
  let!(:inbox) { create(:inbox, account: account_user.account) }

  describe 'notification_settings' do
    it 'gets created with the right default settings' do
      expect(account_user.user.notification_settings).not_to be_nil

      expect(account_user.user.notification_settings.first.email_conversation_creation?).to be(false)
      expect(account_user.user.notification_settings.first.email_conversation_assignment?).to be(false)
      expect(account_user.user.notification_settings.first.selected_inbox_flags.map(&:to_s))
        .to match_array(NotificationSetting.default_inbox_flag_names.map(&:to_s))
      expect(account_user.user.notification_settings.first.push_conversation_assignment?).to be(true)
    end
  end

  describe 'default inbox membership' do
    it 'adds a new workspace employee to every active inbox in that workspace only' do
      second_inbox = create(:inbox, account: account_user.account)
      foreign_inbox = create(:inbox)
      new_user = create(:user)

      membership = create(:account_user, account: account_user.account, user: new_user, role: :agent)

      expect(new_user.inboxes.ids).to contain_exactly(inbox.id, second_inbox.id)
      expect(new_user.inboxes.ids).not_to include(foreign_inbox.id)
      expect(membership.reload.role).to eq('agent')
    end

    it 'preserves unsaved account feature flags while joining the new employee to inboxes' do
      membership = account_user
      dirty_account = membership.account
      persisted_feature_flags = dirty_account.feature_flags
      dirty_account.feature_flags = persisted_feature_flags + 1
      inbox.inbox_members.where(user: membership.user).destroy_all
      expect(inbox.reload.members.ids).not_to include(membership.user_id)

      membership.send(:join_account_inboxes)

      expect(membership).to be_persisted
      expect(inbox.reload.members.ids).to include(membership.user_id)
      expect(dirty_account.feature_flags).to eq(persisted_feature_flags + 1)
      expect(dirty_account.changes_to_save).to include('feature_flags' => [persisted_feature_flags, persisted_feature_flags + 1])
      expect(Account.find(dirty_account.id).feature_flags).to eq(persisted_feature_flags)
    end

    it 'does not duplicate a membership that already exists' do
      new_user = create(:user)
      existing_member = create(:inbox_member, inbox: inbox, user: new_user)

      expect do
        create(:account_user, account: account_user.account, user: new_user)
      end.not_to change(InboxMember, :count)

      expect(inbox.inbox_members.where(user: new_user).ids).to eq([existing_member.id])
    end

    it 'does not join inboxes undergoing deletion' do
      deleting_inbox = create(:inbox, account: account_user.account, deleting_at: Time.current)
      attempted_inbox = create(:inbox, account: account_user.account, deletion_attempt_id: SecureRandom.uuid)
      new_user = create(:user)

      create(:account_user, account: account_user.account, user: new_user)

      expect(new_user.inboxes.ids).to eq([inbox.id])
      expect(deleting_inbox.members.ids).not_to include(new_user.id)
      expect(attempted_inbox.members.ids).not_to include(new_user.id)
    end

    it 'does not join inboxes when the workspace is marked for deletion' do
      account_user.account.update!(custom_attributes: { 'marked_for_deletion_at' => Time.current.iso8601 })
      new_user = create(:user)

      create(:account_user, account: account_user.account, user: new_user)

      expect(new_user.inboxes).to be_empty
    end

    it 'does not restore manually removed memberships when the workspace member is updated' do
      inbox.remove_members([account_user.user_id])

      account_user.update!(availability: :busy)

      expect(inbox.reload.members).to be_empty
    end

    it 'invalidates inbox data after adding the new workspace employee' do
      allow(account_user.account).to receive(:update_cache_key).and_call_original

      create(:account_user, account: account_user.account)

      expect(account_user.account).to have_received(:update_cache_key).with('inbox')
    end
  end

  describe 'permissions' do
    it 'returns the right permissions' do
      expect(account_user.permissions).to eq(['agent'])
    end

    it 'returns the right permissions for administrator' do
      account_user.administrator!
      expect(account_user.permissions).to eq(['administrator'])
    end
  end

  describe 'destroy call agent::destroy service' do
    it 'gets created with the right default settings' do
      create(:conversation, account: account_user.account, assignee: account_user.user, inbox: inbox)
      user = account_user.user

      expect(user.assigned_conversations.count).to eq(1)

      perform_enqueued_jobs do
        account_user.destroy!
      end

      expect(user.assigned_conversations.count).to eq(0)
    end
  end
end
