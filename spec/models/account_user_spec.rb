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

  describe 'permissions' do
    it 'returns the right permissions' do
      expect(account_user.permissions).to eq(['agent'])
    end

    it 'returns the right permissions for administrator' do
      account_user.administrator!
      expect(account_user.permissions).to eq(['administrator'])
    end
  end

  describe 'access role' do
    it 'allows a role from the same account' do
      role = create(:access_role, account: account_user.account)

      expect(account_user.update(access_role: role)).to be(true)
    end

    it 'rejects a role from another account' do
      account_user.access_role = create(:access_role)

      expect(account_user).not_to be_valid
      expect(account_user.errors[:access_role]).to include('must belong to the same account')
    end

    it 'enforces account isolation at the database boundary' do
      other_role = create(:access_role)

      expect do
        described_class.transaction(requires_new: true) do
          # Bypass model validation intentionally to verify the tenant foreign key.
          account_user.update_column(:access_role_id, other_role.id) # rubocop:disable Rails/SkipsModelValidations
        end
      end.to raise_error(ActiveRecord::InvalidForeignKey)
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
