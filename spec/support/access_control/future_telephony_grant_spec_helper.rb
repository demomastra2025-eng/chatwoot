module FutureTelephonyGrantSpecHelper
  def simulate_bridge_catalog!
    catalog = AccessRoleGrant::RESOURCE_CAPABILITIES.except('telephony_calls').freeze
    stub_const('AccessRoleGrant::RESOURCE_CAPABILITIES', catalog)
    stub_const('AccessRoleGrant::RESOURCES', catalog.keys.freeze)
    stub_const('AccessControl::SystemRoleCatalog::BOOTSTRAP_RESOURCES', catalog.keys.freeze)
  end

  def insert_future_telephony_grant(role:, capability: 'view', scope: 'own')
    attributes = {
      account_id: role.account_id,
      access_role_id: role.id,
      resource: 'telephony_calls',
      capability: capability,
      access_scope: scope,
      created_at: Time.current,
      updated_at: Time.current
    }
    id = AccessRoleGrant.insert_all!([attributes]).rows.first.first # rubocop:disable Rails/SkipsModelValidations
    AccessRoleGrant.find(id)
  end
end
