# == Schema Information
#
# Table name: account_users
#
#  id                       :bigint           not null, primary key
#  active_at                :datetime
#  auto_offline             :boolean          default(TRUE), not null
#  availability             :integer          default("online"), not null
#  role                     :integer          default("agent")
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  account_id               :bigint
#  agent_capacity_policy_id :bigint
#  custom_role_id           :bigint
#  inviter_id               :bigint
#  user_id                  :bigint
#
# Indexes
#
#  index_account_users_on_account_id                (account_id)
#  index_account_users_on_agent_capacity_policy_id  (agent_capacity_policy_id)
#  index_account_users_on_custom_role_id            (custom_role_id)
#  index_account_users_on_user_id                   (user_id)
#  uniq_user_id_per_account_id                      (account_id,user_id) UNIQUE
#

class AccountUser < ApplicationRecord
  include AvailabilityStatusable

  belongs_to :account
  belongs_to :user
  belongs_to :inviter, class_name: 'User', optional: true
  belongs_to :access_role, optional: true

  enum role: { agent: 0, administrator: 1 }
  enum availability: { online: 0, offline: 1, busy: 2 }

  accepts_nested_attributes_for :account

  before_validation :synchronize_access_role, if: :access_role_identity_changed?
  after_create_commit :notify_creation, :create_notification_setting
  after_destroy :notify_deletion, :remove_user_from_account
  after_save :update_presence_in_redis, if: :saved_change_to_availability?

  validates :user_id, uniqueness: { scope: :account_id }
  validate :access_role_belongs_to_account

  def create_notification_setting
    setting = user.notification_settings.find_or_initialize_by(account_id: account.id)
    return if setting.persisted?

    setting.selected_email_flags = []
    setting.selected_inbox_flags = NotificationSetting.default_inbox_flag_names
    setting.selected_push_flags = [:push_conversation_assignment]
    setting.selected_telegram_flags = []
    setting.save!
  end

  def remove_user_from_account
    ::Agents::DestroyJob.perform_later(account, user)
  end

  def permissions
    administrator? ? ['administrator'] : ['agent']
  end

  def push_event_data
    {
      id: id,
      availability: availability,
      role: role,
      user_id: user_id
    }
  end

  private

  def synchronize_access_role
    return if account.blank?
    return if new_record? && access_role_id?

    self.access_role = if custom_role_id?
                         access_role_for_custom_role
                       else
                         account.access_roles.find_by(system_key: administrator? ? 'administrator' : 'employee')
                       end
  end

  def access_role_for_custom_role
    return if administrator?

    custom_role_record = CustomRole.find_by(id: custom_role_id, account_id: account_id)
    return unless custom_role_record
    return unless AccessControl::LegacyCustomRoleMapper.analyze(custom_role_record).mappable?

    account.access_roles.find_by(legacy_custom_role_id: custom_role_id)
  end

  def access_role_identity_changed?
    new_record? || will_save_change_to_role? || will_save_change_to_custom_role_id?
  end

  def access_role_belongs_to_account
    return if access_role.blank? || access_role.account_id == account_id

    errors.add(:access_role, 'must belong to the same account')
  end

  def notify_creation
    Rails.configuration.dispatcher.dispatch(AGENT_ADDED, Time.zone.now, account: account)
  end

  def notify_deletion
    Rails.configuration.dispatcher.dispatch(AGENT_REMOVED, Time.zone.now, account: account)
  end

  def update_presence_in_redis
    OnlineStatusTracker.set_status(account.id, user.id, availability)
  end
end

AccountUser.prepend_mod_with('AccountUser')
AccountUser.include_mod_with('Audit::AccountUser')
AccountUser.include_mod_with('Concerns::AccountUser')
