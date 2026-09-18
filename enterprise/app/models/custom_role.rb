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
  # Deletion uses a fresh scoped lookup in destroy_materialized_access_role to avoid stale association state.
  has_one :access_role, foreign_key: :legacy_custom_role_id, dependent: nil, inverse_of: :legacy_custom_role

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
  validate :legacy_access_role_mutation_allowed, if: :access_role_writer_change?
  validate :permissions_remain_compatible_when_enforced, if: :will_save_change_to_permissions?

  before_validation :lock_account_for_access_control
  before_destroy :lock_account_for_access_control, prepend: true
  before_destroy :ensure_legacy_access_role_destruction_allowed
  before_destroy :destroy_materialized_access_role
  after_save :reconcile_materialized_access_role, if: :access_role_reconciliation_required?

  def with_canonical_access_role_mutation
    previous_authorization = @canonical_access_role_mutation_authorized
    @canonical_access_role_mutation_authorized = true
    yield self
  ensure
    @canonical_access_role_mutation_authorized = previous_authorization unless frozen?
  end

  private

  def legacy_access_role_mutation_allowed
    return if canonical_access_role_mutation_authorized?
    return if account && AccessControl::AccessRoleMutator.legacy_mutations_enabled_for?(account: account)

    errors.add(:base, 'Legacy role mutations are disabled for this account')
  end

  def ensure_legacy_access_role_destruction_allowed
    legacy_access_role_mutation_allowed
    throw(:abort) if errors[:base].include?('Legacy role mutations are disabled for this account')
  end

  def canonical_access_role_mutation_authorized?
    @canonical_access_role_mutation_authorized == true
  end

  def access_role_writer_change?
    new_record? || will_save_change_to_name? || will_save_change_to_description? || will_save_change_to_permissions?
  end

  def permissions_remain_compatible_when_enforced
    return unless account&.access_control_mode_enforced?

    if persisted? && canonical_access_role?
      errors.add(:permissions, 'cannot be changed while access control is enforced')
    elsif !AccessControl::LegacyCustomRoleMapper.analyze(self).mappable?
      errors.add(:permissions, 'must be representable while access control is enforced')
    end
  end

  def reconcile_materialized_access_role
    analysis = AccessControl::LegacyCustomRoleMapper.analyze(self)
    return unless analysis.mappable?
    return if account.access_control_mode_legacy? && !AccessRole.exists?(legacy_custom_role_id: id)

    AccessControl::LegacyCustomRoleMapper.call(
      custom_role: self,
      reconcile_grants: !canonical_access_role?
    )
  end

  def canonical_access_role?
    AccessRole.exists?(legacy_custom_role_id: id, grant_source: 'canonical')
  end

  def access_role_reconciliation_required?
    saved_change_to_name? || saved_change_to_description? || saved_change_to_permissions?
  end

  def destroy_materialized_access_role
    role = AccessRole.find_by(account_id: account_id, legacy_custom_role_id: id)
    return unless role
    return if role.destroy

    messages = role.errors.full_messages.presence || ['Access role could not be deleted']
    messages.each { |message| errors.add(:base, message) }
    throw(:abort)
  end
end
