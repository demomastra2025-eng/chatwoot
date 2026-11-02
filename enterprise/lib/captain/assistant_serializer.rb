# frozen_string_literal: true

# The public assistant profile for HTTP, account tools and MCP. Archives and unknown
# fields never cross this boundary, including inside otherwise public config objects.
class Captain::AssistantSerializer
  ACCESS_SCOPE = { 'enabled' => :boolean, 'tool_ids' => [:string] }.freeze
  CONTEXT_SCOPE = { 'enabled' => :boolean, 'field_ids' => [:string] }.freeze
  REASON = { 'id' => :string, 'label' => :string, 'active' => :boolean }.freeze
  FOLLOW_UP_STEP = { 'mode' => :string, 'message' => :string, 'objective' => :string, 'delay_seconds' => :number }.freeze

  def self.config_schema(prompt_access: true)
    voice = Telephony::AiVoice::VoiceSettingsDefaults::DEFAULTS.transform_values do |default|
      default.is_a?(Array) ? [:scalar] : :scalar
    end
    voice = voice.except(*Captain::AssistantConfigContract::VOICE_PROMPT_FIELDS) unless prompt_access
    follow_up = { 'enabled' => :boolean, 'steps' => [FOLLOW_UP_STEP] }
    follow_up['prompt'] = :string if prompt_access
    {
      'context_access' => Captain::ContextFields::SCOPES.map(&:to_s).index_with { CONTEXT_SCOPE },
      'tool_access' => Captain::ToolAccess::SCOPE_ORDER.index_with { ACCESS_SCOPE },
      'capabilities' => { 'version' => :number, 'scopes' => Captain::ToolAccess::SCOPE_ORDER.index_with { ACCESS_SCOPE } },
      'voice_settings' => voice, 'follow_up_settings' => follow_up,
      'outcome_reason_settings' => %w[completion_reasons handoff_reasons].index_with { [REASON] }
    }
  end

  def self.unknown_fields(value, schema = config_schema, path = 'config')
    return [] unless value.respond_to?(:keys) && schema.is_a?(Hash)

    value.keys.flat_map do |key|
      field = "#{path}.#{key}"
      next [field] unless schema.key?(key.to_s)

      unknown_nested_fields(value[key], schema[key.to_s], field)
    end
  end

  def self.unknown_nested_fields(value, schema, path)
    return [] if value.nil?
    return object_unknown_fields(value, schema, path) if schema.is_a?(Hash)
    return value.is_a?(Array) ? array_unknown_fields(value, schema.first, path) : [path] if schema.is_a?(Array)

    value.respond_to?(:keys) || value.is_a?(Array) ? [path] : []
  end

  def self.object_unknown_fields(value, schema, path)
    value.respond_to?(:keys) ? unknown_fields(value, schema, path) : [path]
  end

  def self.array_unknown_fields(value, schema, path)
    value.each_with_index.flat_map { |item, index| unknown_nested_fields(item, schema, "#{path}.#{index}") }
  end
  private_class_method :unknown_nested_fields, :array_unknown_fields, :object_unknown_fields

  def initialize(assistant, user:, impersonation: nil)
    @assistant = assistant
    @prompt_access = Captain::PromptInspectorAccess.allowed?(user: user, impersonation: impersonation)
  end

  def profile
    {
      id: @assistant.id, account_id: @assistant.account_id, name: @assistant.name,
      usage_mode: @assistant.usage_mode, active: @assistant.active?, routing_description: @assistant.routing_description,
      created_at: @assistant.created_at&.iso8601, updated_at: @assistant.updated_at&.iso8601
    }.tap { |result| result[:description] = @assistant.description if @prompt_access }
  end

  def config
    schema = self.class.config_schema(prompt_access: @prompt_access)
    schema = schema.except('tool_access') if Captain::Capabilities.configured?(@assistant.config)
    PublicJsonFields.project(@assistant.config, schema)
  end

  def api_payload
    profile.merge(
      type: 'captain_assistant', config: config, avatar_url: @assistant.avatar_url,
      created_at: @assistant.created_at.to_i, updated_at: @assistant.updated_at.to_i,
      effective_settings: Captain::AssistantConfigContract.effective_settings(@assistant),
      voice_inbox_ids: @assistant.voice_inbox_ids, legacy_scenario_id: @assistant.legacy_scenario_id,
      migration_warnings: [], outcome_reason_options: Captain::OutcomeReasonConfig.new(@assistant).normalized_settings
    )
  end
end
