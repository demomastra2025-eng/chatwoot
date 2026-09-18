json.data @access_roles do |access_role|
  json.id access_role.id
  json.name access_role.name
  json.description access_role.description
  json.system_key access_role.system_key
  json.role_kind access_role.system_key? ? 'system' : 'custom'
  json.legacy_custom_role_id access_role.legacy_custom_role_id
  json.assigned_users_count @assignment_counts.fetch(access_role.id, 0)
  json.grants access_role.grants.sort_by { |grant| [grant.resource, grant.capability] } do |grant|
    json.resource grant.resource
    json.capability grant.capability
    json.access_scope grant.access_scope
  end
end

json.meta do
  json.resources AccessRoleGrant::RESOURCE_CAPABILITIES
  json.access_scopes AccessRoleGrant::ACCESS_SCOPES
end
