# frozen_string_literal: true

# Runtime safety preferences of a Captain run. Safety is never a per-agent
# choice. The client has ONE workspace-wide switch, "moderation_enabled" in the
# "safety" section of Captain::AccountSettings, and every customer-facing agent
# of the workspace follows it. Everything else (the instruction-hijacking and
# credentials checks, their actions, the failure mode) is platform-level and
# comes from the platform runtime preferences (Account#captain_runtime_preferences).
# The internal Copilot has no workspace section and uses the platform
# preferences only.
#
# Data that is stored but not read here and kept untouched: a legacy
# config['safety_settings'] on an agent, and the workspace
# prompt_injection_action / sensitive_info_action values (the client cannot see
# or change them any more; the platform default "block" applies).
class Captain::AssistantSafetyPreferences
  WORKSPACE_SETTINGS = {
    'moderation_enabled' => ['assistant_moderation', [true, false]]
  }.freeze

  def self.for(assistant:, feature:, account: assistant&.account)
    account ||= assistant&.account
    preferences = account&.captain_runtime_preferences.to_h.stringify_keys
    return preferences unless feature.to_s == 'assistant'

    settings = workspace_settings(assistant, account)
    WORKSPACE_SETTINGS.each do |setting_key, (runtime_key, allowed_values)|
      value = settings[setting_key]
      preferences[runtime_key] = value if allowed_values.include?(value)
    end

    preferences
  end

  def self.workspace_settings(assistant, account)
    return assistant.account_settings.section('safety') if assistant && assistant.account_id == account&.id
    return Captain::AccountSettings.new(account).section('safety') if account

    {}
  end
end
