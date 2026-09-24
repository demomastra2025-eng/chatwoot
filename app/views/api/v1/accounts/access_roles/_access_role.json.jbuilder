json.id access_role.id
json.name access_role.name
json.description access_role.description
json.system_key access_role.system_key
json.role_kind access_role.system_key? ? 'system' : 'custom'
json.grant_source access_role.grant_source
json.legacy_custom_role_id access_role.legacy_custom_role_id
json.lock_version access_role.lock_version
json.assigned_users_count assigned_users_count
json.grants access_role.grants.reject { |grant| AccessControl::FutureTelephonyGrant.bridge_only? && AccessControl::FutureTelephonyGrant.valid?(grant) }
                       .sort_by { |grant| [grant.resource, grant.capability] } do |grant|
  json.resource grant.resource
  json.capability grant.capability
  json.access_scope grant.access_scope
end
