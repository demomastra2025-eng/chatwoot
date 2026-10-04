json.data do
  json.partial! 'api/v1/models/user', formats: [:json], resource: resource,
                impersonation_context: local_assigns[:impersonation_context]
end
