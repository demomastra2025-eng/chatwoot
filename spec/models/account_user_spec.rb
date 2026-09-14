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

    it 'assigns the matching system role for a new plain user when presets exist' do
      account = create(:account)
      roles = AccessControl::SystemRoleBootstrapper.call(account: account).roles_by_key

      agent = create(:account_user, account: account, role: :agent)
      administrator = create(:account_user, account: account, role: :administrator)

      expect(agent.access_role).to eq(roles.fetch('employee'))
      expect(administrator.access_role).to eq(roles.fetch('administrator'))
    end

    it 'resynchronizes access role when the legacy identity changes' do
      account = create(:account)
      roles = AccessControl::SystemRoleBootstrapper.call(account: account).roles_by_key
      custom_role = create(:custom_role, account: account, permissions: %w[crm_task_view])
      mapped_role = AccessControl::LegacyCustomRoleMapper.call(custom_role: custom_role)
      account_user = create(:account_user, account: account, role: :agent)

      account_user.update!(custom_role: custom_role)
      expect(account_user.access_role).to eq(mapped_role)

      account_user.update!(role: :administrator)
      expect(account_user.access_role).to be_nil

      account_user.update!(custom_role: nil)
      expect(account_user.access_role).to eq(roles.fetch('administrator'))
    end

    it 'does not reuse a stale mapping after a custom role becomes unsupported' do
      account = create(:account)
      custom_role = create(:custom_role, account: account, permissions: %w[crm_task_view])
      AccessControl::LegacyCustomRoleMapper.call(custom_role: custom_role)
      custom_role.update!(permissions: %w[report_manage])

      account_user = create(:account_user, account: account, role: :agent)
      account_user.update!(custom_role: custom_role)

      expect(account_user.access_role).to be_nil
    end

    it 'rejects an assignment that diverges from legacy identity in enforced mode' do
      account = create(:account)
      roles = AccessControl::SystemRoleBootstrapper.call(account: account).roles_by_key
      account_user = create(:account_user, account: account, role: :agent)
      AccessControl::ModeTransition.call(account: account, to: :shadow)
      AccessControl::ModeTransition.call(account: account, to: :enforced)

      expect(account_user.update(access_role: roles.fetch('observer'))).to be(false)
      expect(account_user.errors[:access_role]).to include('must match the legacy identity while access control is enforced')
      expect(account_user.reload.access_role).to eq(roles.fetch('employee'))
    end

    it 'keeps a changed legacy identity synchronized in enforced mode' do
      account = create(:account)
      roles = AccessControl::SystemRoleBootstrapper.call(account: account).roles_by_key
      account_user = create(:account_user, account: account, role: :agent)
      AccessControl::ModeTransition.call(account: account, to: :shadow)
      AccessControl::ModeTransition.call(account: account, to: :enforced)

      account_user.update!(role: :administrator)

      expect(account_user.access_role).to eq(roles.fetch('administrator'))
    end

    it 'rejects an unsupported custom role assignment in enforced mode' do
      account = create(:account)
      AccessControl::SystemRoleBootstrapper.call(account: account)
      account_user = create(:account_user, account: account, role: :agent)
      unsupported = create(:custom_role, account: account, permissions: %w[report_manage])
      AccessControl::ModeTransition.call(account: account, to: :shadow)
      AccessControl::ModeTransition.call(account: account, to: :enforced)

      expect(account_user.update(custom_role: unsupported)).to be(false)
      expect(account_user.errors[:access_role]).to include('must match the legacy identity while access control is enforced')
      expect(account_user.reload.custom_role).to be_nil
    end
  end

  describe 'destroy call agent::destroy service' do
    it 'gets created with the right default settings' do
      create(:conversation, account: account_user.account, assignee: account_user.user, inbox: inbox)
      communication_thread = create(:communication_thread, account: account_user.account)
      membership = create(
        :communication_thread_participant,
        account: account_user.account,
        communication_thread: communication_thread,
        user: account_user.user
      )
      user = account_user.user

      expect(user.assigned_conversations.count).to eq(1)

      perform_enqueued_jobs do
        account_user.destroy!
      end

      expect(user.assigned_conversations.count).to eq(0)
      expect(CommunicationThreadParticipant.where(id: membership.id)).not_to exist
    end
  end
end
