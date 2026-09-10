module AccessControl::LegacyIdentityCompatible
  extend ActiveSupport::Concern

  private

  def access_role_matches_enforced_identity
    return unless account&.access_control_mode_enforced?

    expected_role = expected_access_role_for_legacy_identity
    return if expected_role && access_role == expected_role

    errors.add(:access_role, 'must match the legacy identity while access control is enforced')
  end

  def expected_access_role_for_legacy_identity
    return if legacy_administrator? && custom_role_id?
    return expected_system_access_role unless custom_role_id?

    custom_role_record = custom_role
    return unless custom_role_record&.account_id == account_id
    return unless AccessControl::LegacyCustomRoleMapper.analyze(custom_role_record).mappable?

    account.access_roles.find_by(legacy_custom_role_id: custom_role_id)
  end

  def expected_system_access_role
    account.access_roles.find_by(system_key: legacy_administrator? ? 'administrator' : 'employee')
  end

  def legacy_administrator?
    role.to_s == 'administrator'
  end
end
