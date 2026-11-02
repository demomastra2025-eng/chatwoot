serializer = Captain::AssistantSerializer.new(resource, user: Current.user, impersonation: @super_admin_impersonation)
json.merge! serializer.api_payload
