# rubocop:disable Metrics/ClassLength
class Api::V1::Accounts::Captain::AssistantsController < Api::V1::Accounts::BaseController
  ASSISTANT_CONFIG_FIELDS = [
    :feature_faq, :feature_memory, :feature_citation, :feature_web, :feature_document_reading,
    :model, :feature_image_understanding, :handoff_enabled, :auto_completion_enabled,
    :welcome_message, :handoff_message, :resolution_message,
    :handoff_message_enabled, :handoff_message_mode,
    :resolution_message_enabled, :resolution_message_mode,
    :temperature,
    :auto_reply_on_last_incoming,
    :use_audio_transcriptions,
    :message_collapse_window_seconds, :history_message_limit
  ].freeze
  ASSISTANT_SAFETY_SETTINGS_FIELDS = %i[
    moderation_enabled prompt_injection_action sensitive_info_action
  ].freeze
  VOICE_SETTINGS_ARRAY_FIELDS = Telephony::AiVoice::VoiceSettingsDefaults::ARRAY_KEYS.index_with { [] }.freeze
  VOICE_SETTINGS_SCALAR_FIELDS = (Telephony::AiVoice::VoiceSettingsDefaults::DEFAULTS.keys - VOICE_SETTINGS_ARRAY_FIELDS.keys).freeze

  before_action :current_account
  before_action -> { check_authorization(Captain::Assistant) }

  before_action :set_assistant, only: [:show, :update, :destroy, :playground, :avatar, :prompt_preview, :voice_preview]
  before_action :ensure_internal_playground_available, only: :playground

  def index
    @assistants = account_assistants.ordered
  end

  def show
    return if @assistant.internal_assistant?

    model = @assistant.resolved_agent_model
    metadata = Llm::Models.feature_config(:assistant, account: Current.account, model_names: [model])
    @playground_model = metadata&.fetch(:models, [])&.first || {
      id: model, supports_temperature: false, capabilities: [], reasoning_efforts: []
    }
  end

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
      cancel_captain_follow_ups_if_disabled!
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
    @playground_test_overrides, invalid_override = playground_test_overrides
    return render json: { error: 'unsupported_playground_setting', field: invalid_override }, status: :unprocessable_entity if invalid_override

    response = @assistant.internal_assistant? ? copilot_playground_response : agent_playground_response

    render json: response
  rescue Captain::Playground::SessionStore::Busy, Captain::Playground::SessionStore::Stale => e
    render json: { error: 'playground_session_conflict', message: e.message }, status: :conflict
  rescue Pundit::NotAuthorizedError
    render json: { error: 'playground_live_forbidden' }, status: :forbidden
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    render json: { error: 'invalid_playground_scenario', message: e.message }, status: :unprocessable_entity
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

  # An internal assistant's playground runs the retired employee Copilot chat
  # (Captain::Copilot::ChatService). The customer-facing agent playground stays.
  def ensure_internal_playground_available
    return unless @assistant.internal_assistant?
    return if Captain::Copilot::ChatAvailability.enabled?

    render json: { error: Captain::Copilot::ChatAvailability::DISABLED_ERROR }, status: :gone
  end

  def account_assistants
    @account_assistants ||= Captain::Assistant.for_account(Current.account.id).with_attached_avatar
  end

  def assistant_params
    permitted = params.require(:assistant).permit(
      :name,
      :description,
      :usage_mode,
      config: ASSISTANT_CONFIG_FIELDS + [{ safety_settings: ASSISTANT_SAFETY_SETTINGS_FIELDS }]
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
    if incoming_config.key?('safety_settings')
      incoming_config['safety_settings'] = existing_config['safety_settings'].to_h.deep_stringify_keys
                                                                             .merge(incoming_config['safety_settings'].to_h.deep_stringify_keys)
    end

    attributes.merge(config: existing_config.merge(incoming_config))
  end

  def cancel_captain_follow_ups_if_disabled!
    settings = @assistant.config.to_h.deep_stringify_keys['follow_up_settings'].to_h
    return if settings['enabled'] == true

    Current.account.reminders.captain_follow_up.open_statuses
           .where("metadata -> 'captain_follow_up' ->> 'assistant_id' = ?", @assistant.id.to_s)
           .find_each(&:cancel!)
  end

  def normalize_outcome_reason_settings!(config, existing_settings = nil)
    return unless config.key?('outcome_reason_settings')

    merged = existing_settings.to_h.deep_merge(config['outcome_reason_settings'].to_h)
    config['outcome_reason_settings'] = Captain::OutcomeReasonConfig.normalize_settings(merged)
  end

  def normalized_voice_settings(*sources)
    merged = sources.each_with_object({}) do |source, settings|
      settings.merge!(source) if source.is_a?(Hash)
    end
    Telephony::AiVoice::VoiceSettingsDefaults.normalize(merged)
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
    params.require(:assistant).permit(
      :message_content,
      :conversation_id,
      :test_model,
      :test_temperature,
      :test_thinking_effort,
      :playground_mode,
      :playground_session_id,
      :playground_action,
      :live_inbox_id,
      :external_delivery_enabled,
      :controlled_test_number,
      scenario: {},
      message_history: [:role, :content, :agent_name]
    )
  end

  def agent_playground_response
    attributes = playground_params
    mode = attributes[:playground_mode].presence || 'trial'
    action = attributes[:playground_action].presence || 'message'
    raise ArgumentError, 'Invalid Playground action' unless %w[message session reset].include?(action)
    raise ArgumentError, 'Trial cannot use a real conversation' if mode == 'trial' && attributes[:conversation_id].present?

    session = Captain::Playground::Session.new(
      assistant: @assistant, account: Current.account, user: Current.user, mode: mode, session_id: attributes[:playground_session_id]
    )
    session.with_lock(
      reset: action == 'reset', scenario_input: attributes[:scenario]&.to_h,
      inbox_id: attributes[:live_inbox_id], delivery_enabled: attributes[:external_delivery_enabled],
      delivery_target: attributes[:controlled_test_number]
    ) do
      if attributes[:conversation_id].present? && attributes[:conversation_id].to_s != session.conversation&.display_id.to_s
        raise ArgumentError, 'Live conversation does not match this Playground session'
      end
      next { playground: session.payload } unless action == 'message'

      options = { assistant: @assistant, source: 'playground', playground_session: session }
      options[:test_overrides] = @playground_test_overrides if @playground_test_overrides.present?
      response = Captain::Assistant::AgentRunnerService.new(**options).generate_response(
        message_history: session.history_with(attributes[:message_content])
      )
      session.record_turn(attributes[:message_content], response)
      response.merge('playground' => session.payload, 'delivery' => Captain::Playground::ReplyDelivery.new(session).perform(response))
    end
  end

  def playground_test_overrides
    attributes = playground_params
    if @assistant.internal_assistant?
      unsupported_field = %i[test_model test_temperature test_thinking_effort].find do |field|
        attributes[field].present?
      end
      return [nil, unsupported_field] if unsupported_field
    end

    effective_model = @assistant.resolved_agent_model
    overrides = {}

    if attributes[:test_model].present?
      requested_model = Llm::Models.canonical_model_name(attributes[:test_model])
      selectable_models = Llm::Models.curated_model_names_for(:assistant, account: Current.account)
      selectable_models += [@assistant.model, Llm::Config.model_for(feature: :assistant, account: Current.account)].compact_blank
      unless selectable_models.include?(requested_model) && Llm::Models.valid_model_for?(:assistant, requested_model, account: Current.account)
        return [nil, 'test_model']
      end

      effective_model = requested_model
      overrides[:model] = requested_model
    end

    if attributes.key?(:test_temperature)
      temperature = Float(attributes[:test_temperature])
      return [nil, 'test_temperature'] unless temperature.finite? && temperature.between?(0.0, 1.0)
      return [nil, 'test_temperature'] unless Llm::Models.supports_temperature?(effective_model, account: Current.account)

      overrides[:temperature] = temperature
    end

    if attributes[:test_thinking_effort].present?
      effort = attributes[:test_thinking_effort].to_s
      return [nil, 'test_thinking_effort'] unless Llm::RuntimePolicy::THINKING_EFFORTS.include?(effort)
      return [nil, 'test_thinking_effort'] unless Llm::Models.reasoning_efforts_for(effective_model, account: Current.account).include?(effort)

      overrides[:thinking_effort] = effort
    end

    [overrides, nil]
  rescue ArgumentError, TypeError
    [nil, 'test_temperature']
  end

  def copilot_playground_response
    response = Captain::Copilot::ChatService.new(
      @assistant,
      {
        user_id: Current.user.id,
        conversation_id: playground_conversation&.display_id,
        previous_history: copilot_playground_history,
        source: 'playground'
      }.compact
    ).generate_response(playground_params[:message_content])
    payload = response.to_h.deep_stringify_keys

    payload.merge('response' => payload['content'])
  end

  def copilot_playground_history
    history = message_history.map { |message| message.slice(:role, :content) }
    current_message = playground_params[:message_content]
    history.pop if history.last&.slice(:role, :content) == { role: 'user', content: current_message }
    history
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
