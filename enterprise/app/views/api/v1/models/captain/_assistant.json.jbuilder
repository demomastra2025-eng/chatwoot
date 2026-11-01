json.account_id resource.account_id
json.avatar_url resource.avatar_url
prompt_access = Captain::PromptInspectorAccess.allowed?(user: Current.user, impersonation: @super_admin_impersonation)
json.config Captain::AssistantConfigContract.public_config(resource, prompt_access: prompt_access)
json.effective_settings Captain::AssistantConfigContract.effective_settings(resource)
json.created_at resource.created_at.to_i
if prompt_access
  json.description resource.description
end
json.id resource.id
json.name resource.name
json.type 'captain_assistant'
json.updated_at resource.updated_at.to_i
json.usage_mode resource.usage_mode
json.active resource.active?
json.routing_description resource.routing_description
json.voice_inbox_ids resource.voice_inbox_ids
json.legacy_scenario_id resource.legacy_scenario_id
json.migration_warnings resource.config.to_h.dig('legacy_scenario_migration', 'warnings') || []
json.outcome_reason_options Captain::OutcomeReasonConfig.new(resource).normalized_settings
