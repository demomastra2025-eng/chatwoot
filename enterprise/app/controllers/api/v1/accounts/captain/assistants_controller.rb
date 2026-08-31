# rubocop:disable Metrics/ClassLength
class Api::V1::Accounts::Captain::AssistantsController < Api::V1::Accounts::BaseController
  ASSISTANT_CONFIG_FIELDS = [
    :feature_faq, :feature_memory, :feature_citation, :feature_web, :feature_document_reading,
    :welcome_message, :handoff_message, :resolution_message,
    :handoff_message_enabled, :handoff_message_mode,
    :resolution_message_enabled, :resolution_message_mode,
    :temperature,
    :model, :feature_image_understanding,
    :auto_reply_on_last_incoming,
    :handoff_enabled, :auto_completion_enabled,
    :message_collapse_window_seconds, :history_message_limit
  ].freeze
  VOICE_SETTINGS_ARRAY_FIELDS = Telephony::AiVoice::VoiceSettingsDefaults::ARRAY_KEYS.index_with { [] }.freeze
  VOICE_SETTINGS_SCALAR_FIELDS = (Telephony::AiVoice::VoiceSettingsDefaults::DEFAULTS.keys - VOICE_SETTINGS_ARRAY_FIELDS.keys).freeze

  before_action :current_account
  before_action -> { check_authorization(Captain::Assistant) }

  before_action :set_assistant, only: [:show, :update, :destroy, :playground, :avatar, :prompt_preview, :voice_preview]

  def index
    @assistants = account_assistants.ordered
  end

  def show; end

  def create
    attributes = assistant_create_params
    Current.account.with_lock do
      @assistant = account_assistants.create!(attributes)
    end
  rescue ActiveRecord::RecordInvalid => e
    render_fish_voice_reference_error_or_raise(e)
  end

  def update
    attributes = assistant_update_params
    Current.account.with_lock do
      @assistant.update!(attributes)
    end
  rescue ActiveRecord::RecordInvalid => e
    render_fish_voice_reference_error_or_raise(e)
  end

  def avatar
    if request.patch?
      @assistant.update!(avatar: avatar_params[:avatar])
    elsif request.delete?
      @assistant.avatar.purge if @assistant.avatar.attached?
    end
  end

  def destroy
    @assistant.destroy
    head :no_content
  end

  def playground
    render json: agent_playground_response
  rescue Rack::Timeout::RequestTimeoutException, Rack::Timeout::RequestTimeoutError => e
    Rails.logger.warn(
      "#{self.class.name} playground timed out for assistant #{@assistant.id}: #{e.class} - #{e.message}"
    )

    render json: { response: nil, timed_out: true }
  end

  def tools
    assistant = params[:assistant_id].present? ? account_assistants.find(params[:assistant_id]) : Captain::Assistant.new(account: Current.account)
    scope_name = params[:scope].presence
    tools = Captain::ToolAccess.definitions_for(assistant)
    @tools =
      if scope_name.present?
        tools.select { |tool| tool[:scope_name].to_s == scope_name }
      else
        tools
      end
  end

  def prompt_preview
    render json: Captain::Assistant::PromptPreviewService.new(assistant: @assistant).preview
  end

  def voice_preview
    context = Telephony::AiVoice::PreviewContextBuilder.new(assistant: @assistant).perform
    preview = Telephony::AiVoice::JanusSipRuntimeClient.new.create_preview(context)
    render json: preview.slice('token', 'expires_in', 'websocket_path')
  rescue Telephony::AiVoice::JanusSipRuntimeClient::ConnectionError,
         Telephony::AiVoice::JanusSipRuntimeClient::AttachError => e
    Rails.logger.warn "[AI VOICE PREVIEW] assistant=#{@assistant.id} unavailable: #{e.class} #{e.message}"
    render(**Telephony::AiVoice::JanusSipRuntimeClient.preview_error_response(e))
  end

  def context_fields
    assistant = params[:assistant_id].present? ? account_assistants.find(params[:assistant_id]) : Captain::Assistant.new(account: Current.account)
    allowed_ids = assistant.selected_context_field_ids

    @context_fields = assistant.available_context_fields.map do |field|
      field.merge(selected: allowed_ids.include?(field[:id]))
    end
  end

  def skills
    @skills = Captain::SkillCatalog.all(account: Current.account)
  end

  private

  def set_assistant
    @assistant = account_assistants.find(params[:id])
  end

  def account_assistants
    @account_assistants ||= Captain::Assistant.for_account(Current.account.id).external_agent.with_attached_avatar
  end

  def assistant_params
    permitted = params.require(:assistant).permit(
      :name,
      :description,
      config: ASSISTANT_CONFIG_FIELDS
    )

    merge_optional_array_param!(permitted, :response_guidelines)
    merge_optional_array_param!(permitted, :guardrails)
    merge_optional_config_param!(permitted, :context_access)
    merge_optional_config_param!(permitted, :tool_access)
    merge_optional_config_param!(permitted, :follow_up_settings)
    merge_optional_config_param!(permitted, :outcome_reason_settings)
    merge_optional_config_param!(permitted, :voice_settings, voice_settings: true)
    merge_optional_config_param!(permitted, :rules)

    permitted
  end

  def assistant_create_params
    attributes = assistant_params.to_h.deep_symbolize_keys
    existing_config = attributes[:config].is_a?(Hash) ? attributes[:config].deep_stringify_keys : {}
    existing_config['voice_settings'] = normalized_voice_settings(existing_config['voice_settings'])
    normalize_outcome_reason_settings!(existing_config)

    attributes.merge(config: existing_config)
  end

  def assistant_update_params
    attributes = assistant_params.to_h.deep_symbolize_keys
    return attributes unless attributes.key?(:config)

    existing_config = @assistant.config.is_a?(Hash) ? @assistant.config.deep_stringify_keys : {}
    incoming_config = attributes[:config].is_a?(Hash) ? attributes[:config].deep_stringify_keys : {}
    if incoming_config.key?('voice_settings')
      incoming_config['voice_settings'] = normalized_voice_settings(existing_config['voice_settings'], incoming_config['voice_settings'])
    end
    normalize_outcome_reason_settings!(incoming_config, existing_config['outcome_reason_settings'])

    attributes.merge(config: existing_config.merge(incoming_config))
  end

  def normalized_voice_settings(*sources)
    merged = sources.each_with_object({}) do |source, settings|
      settings.merge!(source) if source.is_a?(Hash)
    end
    Telephony::AiVoice::VoiceSettingsDefaults.normalize(merged)
  end

  def normalize_outcome_reason_settings!(config, existing_settings = nil)
    return unless config.key?('outcome_reason_settings')

    merged_settings = existing_settings.to_h.deep_merge(config['outcome_reason_settings'].to_h)
    config['outcome_reason_settings'] = Captain::OutcomeReasonConfig.normalize_settings(merged_settings)
  end

  def render_fish_voice_reference_error_or_raise(error)
    raise error unless error.record.errors.of_kind?(:config, :fish_voice_invalid_reference)

    render json: { error: 'fish_voice_invalid_reference' }, status: :unprocessable_content
  end

  def merge_optional_array_param!(permitted, field_name)
    return unless params[:assistant].key?(field_name)

    permitted[field_name] = normalize_optional_array_value(params[:assistant][field_name])
  end

  def normalize_optional_array_value(value)
    Array(normalize_optional_config_value(value)).map do |item|
      item.is_a?(Hash) ? item.to_json : item
    end
  end

  def merge_optional_config_param!(permitted, field_name, voice_settings: false)
    assistant_config = params.dig(:assistant, :config)
    return unless assistant_config.respond_to?(:key?) && assistant_config.key?(field_name)

    raw_value = assistant_config[field_name]
    if voice_settings && raw_value.is_a?(ActionController::Parameters)
      raw_value = raw_value.permit(*VOICE_SETTINGS_SCALAR_FIELDS, VOICE_SETTINGS_ARRAY_FIELDS)
    end
    permitted[:config] ||= {}
    permitted[:config][field_name] = normalize_optional_config_value(raw_value)
  end

  def normalize_optional_config_value(value)
    case value
    when ActionController::Parameters
      value.to_unsafe_h.transform_values { |item| normalize_optional_config_value(item) }
    when Array
      value.map { |item| normalize_optional_config_value(item) }
    when Hash
      value.transform_values { |item| normalize_optional_config_value(item) }
    else
      value
    end
  end

  def avatar_params
    params.permit(:avatar)
  end

  def playground_params
    params.require(:assistant).permit(:message_content, :conversation_id, message_history: [:role, :content, :agent_name])
  end

  def agent_playground_response
    tool_trace = []
    options = {
      assistant: @assistant,
      source: 'playground',
      callbacks: playground_trace_callbacks(tool_trace)
    }
    options[:conversation] = playground_conversation if playground_params[:conversation_id].present?

    response = Captain::Assistant::AgentRunnerService.new(**options).generate_response(message_history: playground_message_history)
    response['tool_trace'] = tool_trace
    response
  end

  def playground_trace_callbacks(tool_trace)
    {
      on_tool_start: ->(*args) { tool_trace << playground_trace_entry('start', args) },
      on_tool_complete: ->(*args) { tool_trace << playground_trace_entry('complete', args) },
      on_tool_error: ->(*args) { tool_trace << playground_trace_entry('error', args) }
    }
  end

  def playground_trace_entry(event, args)
    tool = args.first
    tool_name = if tool.is_a?(String) || tool.is_a?(Symbol)
                  tool
                elsif tool.respond_to?(:name)
                  tool.name
                elsif tool.respond_to?(:tool_name)
                  tool.tool_name
                else
                  tool.class.name.demodulize
                end
    { event: event, tool: tool_name.to_s }
  end

  def playground_conversation
    return if playground_params[:conversation_id].blank?

    @playground_conversation ||= Conversations::PermissionFilterService.new(
      Current.account.conversations,
      Current.user,
      Current.account
    ).perform.find_by!(display_id: playground_params[:conversation_id])
  end

  def message_history
    (playground_params[:message_history] || []).map do |message|
      {
        role: message[:role],
        content: message[:content],
        agent_name: message[:agent_name]
      }.compact
    end
  end

  def playground_message_history
    history = message_history
    current_message = playground_params[:message_content]
    return history if current_message.blank?

    current_user_message = { role: 'user', content: current_message }
    return history if history.last == current_user_message

    history + [current_user_message]
  end
end
# rubocop:enable Metrics/ClassLength
