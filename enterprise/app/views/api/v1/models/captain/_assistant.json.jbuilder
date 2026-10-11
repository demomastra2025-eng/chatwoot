json.account_id resource.account_id
json.avatar_url resource.avatar_url
json.config(resource.config.to_h.except('handoff_requires_explicit_consent', 'handoff_consent_reason', 'rules', 'skills', 'main_prompt_rules_migration'))
json.created_at resource.created_at.to_i
json.description resource.description
json.id resource.id
json.name resource.name
json.type 'captain_assistant'
json.updated_at resource.updated_at.to_i
json.usage_mode resource.usage_mode
json.active resource.active?
json.routing_description resource.routing_description
json.channel_scope resource.channel_scope
json.inbox_ids(resource.channel_scope == 'all' ? [] : resource.selected_inbox_ids)
json.main_in_inbox_ids resource.main_in_inbox_ids
json.legacy_scenario_id resource.legacy_scenario_id
json.migration_warnings resource.config.to_h.dig('legacy_scenario_migration', 'warnings') || []
json.outcome_reason_options Captain::OutcomeReasonConfig.new(resource).normalized_settings
