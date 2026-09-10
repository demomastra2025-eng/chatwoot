# == Schema Information
#
# Table name: custom_roles
#
#  id          :bigint           not null, primary key
#  description :string
#  name        :string
#  permissions :text             default([]), is an Array
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  account_id  :bigint           not null
#
# Indexes
#
#  index_custom_roles_on_account_id  (account_id)
#
#

# Available permissions for custom roles:
# - 'conversation_manage': Can manage all conversations.
# - 'conversation_unassigned_manage': Can manage unassigned conversations and assign to self.
# - 'conversation_participating_manage': Can manage conversations they are participating in (assigned to or a participant).
# - 'conversation_team_manage': Can manage conversations assigned to one of their teams.
# - 'contact_manage': Can manage contacts.
# - 'report_manage': Can manage reports.
# - 'knowledge_base_manage': Can manage knowledge base portals.
# - 'captain_manage': Can manage AI agents.

class CustomRole < ApplicationRecord
  include AccessControl::AccountLockable

  belongs_to :account
  has_many :account_users, dependent: :restrict_with_error
  has_many :account_user_lifecycle_snapshots, dependent: :restrict_with_error
  has_one :access_role, foreign_key: :legacy_custom_role_id, dependent: :restrict_with_error, inverse_of: :legacy_custom_role

  PERMISSIONS = %w[
    conversation_manage
    conversation_unassigned_manage
    conversation_participating_manage
    conversation_team_manage
    contact_manage
    crm_deal_view
    crm_deal_manage
    crm_task_view
    crm_task_manage
    crm_settings_view
    crm_settings_manage
    outbound_view
    outbound_manage
    report_manage
    knowledge_base_manage
    captain_manage
    scheduling_override
  ].freeze

  validates :name, presence: true
  validates :permissions, inclusion: { in: PERMISSIONS }
  validate :permissions_remain_mappable_when_enforced, if: :will_save_change_to_permissions?

  before_validation :lock_account_for_access_control
  before_destroy :lock_account_for_access_control
  after_save :reconcile_materialized_access_role, if: :saved_change_to_permissions?

  private

  def permissions_remain_mappable_when_enforced
    return unless account&.access_control_mode_enforced?
    return if AccessControl::LegacyCustomRoleMapper.analyze(self).mappable?

    errors.add(:permissions, 'must be representable while access control is enforced')
  end

  def reconcile_materialized_access_role
    return unless AccessRole.exists?(legacy_custom_role_id: id)
    return unless AccessControl::LegacyCustomRoleMapper.analyze(self).mappable?

    AccessControl::LegacyCustomRoleMapper.call(custom_role: self)
  end
end
