# frozen_string_literal: true

# The public assistant profile for HTTP, account tools and MCP. Archives and unknown
# fields never cross this boundary, including inside otherwise public config objects.
class Captain::AssistantSerializer
  ACCESS_SCOPE = { 'enabled' => :boolean, 'tool_ids' => [:string] }.freeze
  CONTEXT_SCOPE = { 'enabled' => :boolean, 'field_ids' => [:string] }.freeze
  REASON = { 'id' => :string, 'label' => :string, 'active' => :boolean }.freeze
  FOLLOW_UP_STEP = { 'mode' => :string, 'message' => :string, 'objective' => :string, 'delay_seconds' => :number }.freeze

  def self.config_schema(prompt_access: true)
    voice = Telephony::AiVoice::PlatformPolicy.schema(prompt_access: prompt_access)
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
    PublicJsonFields.unknown_fields(value, schema, path)
  end

  def initialize(assistant, user:, impersonation: nil)
    @assistant = assistant
    @user = user
    @impersonation = impersonation
    @prompt_access = true
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
    PublicJsonFields.project(@assistant.config, schema).merge(
      'voice_settings' => Telephony::AiVoice::PlatformPolicy.new(
        account: @assistant.account, settings: @assistant.config.to_h['voice_settings']
      ).public_settings(user: @user, impersonation: @impersonation)
    )
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
