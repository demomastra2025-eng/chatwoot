json.data do
  json.partial! 'api/v1/accounts/access_roles/access_role',
                access_role: @access_role,
                assigned_users_count: @assigned_users_count
end
