json.data @access_roles do |access_role|
  json.partial! 'api/v1/accounts/access_roles/access_role',
                access_role: access_role,
                assigned_users_count: @assignment_counts.fetch(access_role.id, 0)
end

json.meta do
  serialized_resources = AccessControl::SystemRoleCatalog::BOOTSTRAP_RESOURCES
  json.resources AccessRoleGrant::RESOURCE_CAPABILITIES.slice(*serialized_resources)
  json.access_scopes AccessRoleGrant::ACCESS_SCOPES
  json.resource_access_scopes AccessRoleGrant::RESOURCE_ACCESS_SCOPES.slice(*serialized_resources)
  json.mutations_enabled AccessControl::AccessRoleMutator.mutations_enabled_for?(account: Current.account)
  json.legacy_mutations_enabled AccessControl::AccessRoleMutator.legacy_mutations_enabled_for?(account: Current.account)
  json.assignments_enabled AccessControl::AccessRoleAssigner.assignments_enabled_for?(account: Current.account)
  json.legacy_assignments_enabled AccessControl::AccessRoleAssigner.legacy_assignments_enabled_for?(account: Current.account)
end
