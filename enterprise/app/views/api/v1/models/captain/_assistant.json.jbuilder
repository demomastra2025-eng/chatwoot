json.account_id resource.account_id
json.avatar_url resource.avatar_url
json.config(resource.config.to_h.merge('rules' => resource.rule_entries.map(&:stringify_keys)))
json.created_at resource.created_at.to_i
json.description resource.description
json.guardrails resource.guardrails
json.id resource.id
json.name resource.name
json.response_guidelines resource.response_guidelines
json.type 'captain_assistant'
json.updated_at resource.updated_at.to_i
json.usage_mode resource.usage_mode
