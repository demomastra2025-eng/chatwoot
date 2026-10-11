# frozen_string_literal: true

class Captain::AssistantSafetyPreferences
  SETTINGS_BY_FEATURE = {
    'assistant' => {
      'moderation_enabled' => ['assistant_moderation', [true, false]],
      'prompt_injection_action' => ['assistant_prompt_injection_guardrail', Llm::RuntimeGuardrailAction::ACTIONS],
      'sensitive_info_action' => ['assistant_sensitive_info_guardrail', Llm::RuntimeGuardrailAction::ACTIONS]
    },
    'copilot' => {
      'moderation_enabled' => ['copilot_moderation', [true, false]],
      'prompt_injection_action' => ['copilot_prompt_injection_guardrail', Llm::RuntimeGuardrailAction::ACTIONS],
      'sensitive_info_action' => ['copilot_sensitive_info_guardrail', Llm::RuntimeGuardrailAction::ACTIONS]
    }
  }.freeze

  def self.for(assistant:, feature:, account: assistant&.account)
    account ||= assistant&.account
    preferences = account&.captain_runtime_preferences.to_h.stringify_keys
    settings = settings_for(assistant, feature, account)

    SETTINGS_BY_FEATURE.fetch(feature.to_s, {}).each do |setting_key, (runtime_key, allowed_values)|
      value = runtime_value(settings[setting_key], setting_key, feature)
      preferences[runtime_key] = value if allowed_values.include?(value)
    end

    preferences
  end

  def self.settings_for(assistant, feature, account)
    return assistant.account_settings.section('safety') if feature.to_s == 'assistant' && assistant

    assistant&.config.to_h.deep_stringify_keys['safety_settings'].to_h
  end

  def self.runtime_value(value, key, feature)
    return value unless key.end_with?('_action') && feature.to_s == 'assistant'

    Captain::AccountSettings::ACTION_FROM_API.fetch(value, value)
  end
end
