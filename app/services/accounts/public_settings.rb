# frozen_string_literal: true

class Accounts::PublicSettings
  BUSINESS_KEYS = %w[
    auto_resolve_after auto_resolve_message auto_resolve_ignore_waiting audio_transcriptions call_transcriptions auto_resolve_label
    keep_pending_on_bot_failure captain_auto_resolve_mode scheduling_contact_required scheduling_company_enabled client_languages
    bilingual_templates_enabled scheduling_last_booking_time scheduling_last_booking_time_by_weekday conversation_assignment_policy_id
    conversation_auto_assignment_enabled conversation_assign_on_first_reply_enabled conversation_assign_on_note_or_resolve_enabled
    workspace_timezone workspace_working_hours workspace_breaks workspace_days_off dashboard_sidebar_item_order
    dashboard_conversation_sidebar_pipeline_visibility conversation_required_attributes conversation_status_reason_config captain_features
  ].freeze
  PLATFORM_KEYS = %w[captain_models captain_runtime captain_observability mcp_access].freeze
  PUBLIC_RUNTIME_KEYS = %w[
    privacy_profile assistant_thinking_effort copilot_thinking_effort assistant_moderation copilot_moderation
    openrouter_allow_model_fallbacks moderation_failure_mode prompt_injection_guardrail sensitive_info_guardrail
    assistant_prompt_injection_guardrail assistant_sensitive_info_guardrail copilot_prompt_injection_guardrail
    copilot_sensitive_info_guardrail knowledge_chunk_size trace_input_capture trace_output_capture openrouter_routing_strategy
    routing_strategy openrouter_provider_order provider_order safety_blocklist assistant_safety_blocklist copilot_safety_blocklist
    agent_high_risk_tools agent_high_risk_tool_ids agent_permissioned_tool_ids web_search_enabled web_scrape_enabled
    web_document_parse_enabled web_search_max_results web_scrape_max_chars web_document_parse_max_chars web_allowed_domains
    web_blocked_domains release_gate
  ].freeze
  MESSAGE = { 'enabled' => :boolean, 'mode' => :string, 'text' => :string, 'instruction' => :string }.freeze
  REASON = { 'id' => :string, 'label' => :string, 'enabled' => :boolean, 'builtin' => :boolean }.freeze
  RULE = %w[id name direction instruction action].index_with { :string }.merge('enabled' => :boolean).freeze
  EXTRA_BUSINESS = {
    'reporting_timezone' => :string, 'dashboard_sidebar_hidden_items_version' => :scalar, 'dashboard_sidebar_hidden_items' => [:string],
    'workspace_greeting' => { 'enabled' => :boolean, 'message' => :string, 'excluded_inbox_ids' => [:scalar] },
    'workspace_out_of_office' => { 'enabled' => :boolean, 'message' => :string }
  }.freeze

  def self.for(account, user:, impersonation: nil)
    new(account, user: user, impersonation: impersonation).value
  end

  def self.runtime_for(account, user:, impersonation: nil)
    new(account, user: user, impersonation: impersonation).runtime
  end

  def initialize(account, user:, impersonation:)
    @account = account
    @platform = defined?(Captain::PromptInspectorAccess) && Captain::PromptInspectorAccess.allowed?(user: user, impersonation: impersonation)
  end

  def value
    properties = schema_properties
    keys = @platform ? BUSINESS_KEYS + PLATFORM_KEYS : BUSINESS_KEYS
    schema = properties.slice(*keys).transform_values { |field| PublicJsonFields.from_json_schema(field) }.merge(EXTRA_BUSINESS)
    schema['captain_agent_settings'] = captain_business_schema if defined?(Captain::AccountSettings)
    PublicJsonFields.project(@account.settings.to_h, schema)
  end

  def runtime
    properties = schema_properties.fetch('captain_runtime').fetch('properties')
    properties = properties.slice(*PUBLIC_RUNTIME_KEYS) unless @platform
    schema = properties.transform_values { |field| PublicJsonFields.from_json_schema(field) }
    PublicJsonFields.project(@account.captain_runtime_preferences.to_h.stringify_keys, schema)
  end

  private

  def schema_properties
    JSON.parse(AccountSettingsSchema::SETTINGS_PARAMS_SCHEMA).fetch('properties')
  end

  def captain_business_schema
    schema = Captain::AccountSettings::BOOLEAN_FIELDS.transform_values { |keys| keys.index_with { :boolean } }
    schema['handoff'].merge!(%w[handoff_message resolution_message].index_with { MESSAGE })
    schema['handoff'].merge!(%w[handoff_reasons completion_reasons].index_with { [REASON] })
    schema['conversation'] = { 'message_collapse_window_seconds' => :number }
    schema['routing']['auto_reply_mode'] = :string
    schema['safety'].merge!('prompt_injection_action' => :string, 'sensitive_info_action' => :string, 'custom_rules' => [RULE])
    schema
  end
end
