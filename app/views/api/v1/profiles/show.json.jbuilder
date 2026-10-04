json.partial! 'api/v1/models/user', formats: [:json], resource: @user,
              impersonation_context: @super_admin_impersonation
