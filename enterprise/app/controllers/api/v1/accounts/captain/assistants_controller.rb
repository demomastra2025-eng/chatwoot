# rubocop:disable Metrics/ClassLength
class Api::V1::Accounts::Captain::AssistantsController < Api::V1::Accounts::BaseController
  ASSISTANT_CONFIG_FIELDS = [
    :feature_faq, :feature_memory, :feature_citation, :feature_web, :feature_document_reading,
    :model, :feature_image_understanding, :handoff_enabled, :auto_completion_enabled,
    :welcome_message, :handoff_message, :resolution_message,
    :handoff_message_enabled, :handoff_message_mode,
    :resolution_message_enabled, :resolution_message_mode,
    :temperature, :thinking_effort,
    :auto_reply_on_last_incoming,
    :use_audio_transcriptions,
    :message_collapse_window_seconds, :history_message_limit
  ].freeze
  VOICE_SETTINGS_ARRAY_FIELDS = Telephony::AiVoice::VoiceSettingsDefaults::ARRAY_KEYS.index_with { [] }.freeze
  VOICE_SETTINGS_SCALAR_FIELDS = (Telephony::AiVoice::VoiceSettingsDefaults::DEFAULTS.keys - VOICE_SETTINGS_ARRAY_FIELDS.keys).freeze

  before_action :current_account
  before_action :hide_prompt_preview_from_clinics, only: :prompt_preview
  before_action -> { check_authorization(Captain::Assistant) }

  before_action :set_assistant, only: [:show, :update, :destroy, :playground, :avatar, :prompt_preview, :voice_preview]
  before_action :ensure_internal_playground_available, only: :playground
  before_action :reject_separate_rules, only: [:create, :update]
  around_action :with_model_metadata_snapshot, only: :show

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
    Current.account.with_lock { @assistant = account_assistants.create!(attributes) }
  rescue ActiveRecord::RecordInvalid => e
    render_profile_validation_error_or_raise(e)
  end

  def update
    attributes = assistant_update_params
    Current.account.with_lock do
      @assistant.update!(attributes)
      cancel_captain_follow_ups_if_disabled!
    end
  rescue ActiveRecord::RecordInvalid => e
    render_profile_validation_error_or_raise(e)
  end

  def avatar
    if request.patch?
      @assistant.update!(avatar: avatar_params[:avatar])
    elsif request.delete?
      @assistant.avatar.purge if @assistant.avatar.attached?
    end
  end

  # Any agent can be deleted. Deleting the voice agent of a number takes that number's AI away (its routing policy is cleared).
  def destroy
    if Current.account.with_lock { @assistant.destroy }
      head :no_content
    else
      render json: { errors: @assistant.errors.full_messages }, status: :unprocessable_content
    end
  end

  # Only the internal assistant has a playground of its own. The customer-facing AI has one for the whole workspace
  # (Api::V1::Accounts::Captain::PlaygroundController): no agent is the start agent of it.
  def playground
    return render_not_found_error('Resource could not be found') unless @assistant.internal_assistant?

    unsupported_field = %i[test_model test_temperature test_thinking_effort].find { |field| playground_params[field].present? }
    return render json: { error: 'unsupported_playground_setting', field: unsupported_field }, status: :unprocessable_entity if unsupported_field

    render json: copilot_playground_response
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    render json: { error: 'invalid_playground_scenario', message: e.message }, status: :unprocessable_entity
  rescue Rack::Timeout::RequestTimeoutException, Rack::Timeout::RequestTimeoutError, Timeout::Error => e
    render_playground_timeout_response(e)
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

  private

  # The policy also needs the verified «Войти как» session to recognise a super admin inside a clinic.
  def pundit_user
    super.merge(super_admin_impersonation: @super_admin_impersonation)
  end

  # The compiled prompt is for the platform team only (Captain::PromptInspectorAccess). A clinic user of any
  # role gets 404, as if the endpoint did not exist, before the assistant is even looked up.
  def hide_prompt_preview_from_clinics
    return if Captain::PromptInspectorAccess.allowed?(user: Current.user, impersonation: @super_admin_impersonation)

    render_not_found_error('Resource could not be found')
  end

  def reject_separate_rules
    attributes = params[:assistant]
    return unless attributes.respond_to?(:key?)

    fields = %w[response_guidelines guardrails].select { |field| attributes.key?(field) }
    fields << 'config.rules' if attributes[:config].respond_to?(:key?) && attributes[:config].key?(:rules)
    return if fields.empty?

    render json: { error: 'separate_rules_removed', fields: fields, message: 'Save instructions in assistant.description.' },
           status: :unprocessable_entity
  end

  def with_model_metadata_snapshot(&)
    return yield if @assistant.internal_assistant?

    Llm::Config.with_runtime_cache do
      Llm::OpenRouterModelCatalog.with_model_configs_snapshot do
        Llm::OpenRouterEndpointCatalog.with_endpoint_configs_snapshot(&)
      end
    end
  end

  def set_assistant
    @assistant = account_assistants.find(params[:id])
  end

  # An internal assistant's playground runs the retired employee Copilot chat
  # (Captain::Copilot::ChatService).
  def ensure_internal_playground_available
    return unless @assistant.internal_assistant?
    return if Captain::Copilot::ChatAvailability.enabled?

    render json: { error: Captain::Copilot::ChatAvailability::DISABLED_ERROR }, status: :gone
  end

  def account_assistants
    @account_assistants ||= Captain::Assistant.for_account(Current.account.id).with_attached_avatar
  end

  # Safety checks are one workspace-wide setting (Captain::AccountSettings), not an agent setting, and an agent has no channel list or
  # transfer list (every enabled agent is a peer in every text channel). config.safety_settings and the old channel and transfer
  # lists are therefore not permitted here: a legacy client may still send them, they are ignored.
  def assistant_params
    permitted = params.require(:assistant).permit(
      :name,
      :description,
      :usage_mode,
      :active,
      :routing_description,
      config: ASSISTANT_CONFIG_FIELDS
    )

    merge_optional_config_param!(permitted, :context_access)
    merge_optional_config_param!(permitted, :tool_access)
    merge_optional_config_param!(permitted, :follow_up_settings)
    merge_optional_config_param!(permitted, :outcome_reason_settings)
    merge_optional_config_param!(permitted, :voice_settings, voice_settings: true)

    permitted
  end

  def assistant_create_params
    attributes = assistant_params.to_h.deep_symbolize_keys
    existing_config = attributes[:config].is_a?(Hash) ? attributes[:config].deep_stringify_keys : {}
    existing_config['voice_settings'] = normalized_voice_settings(existing_config['voice_settings'])
    normalize_outcome_reason_settings!(existing_config)
    existing_config = normalized_model_config(existing_config)

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

    attributes.merge(config: normalized_model_config(existing_config.merge(incoming_config)))
  end

  def normalized_model_config(config)
    model = config['model'].presence || Llm::Config.model_for(feature: :assistant, account: Current.account)
    Llm::ModelParameters.for(model, account: Current.account).normalize_config(config)
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

  def render_profile_validation_error_or_raise(error)
    raise error unless error.record.errors.of_kind?(:config, :fish_voice_invalid_reference)

    render json: { error: 'fish_voice_invalid_reference' }, status: :unprocessable_content
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

  def render_playground_timeout_response(error)
    Rails.logger.warn("#{self.class.name} playground timed out for assistant #{@assistant.id}: #{error.class} - #{error.message}")
    render json: {
      response: nil,
      timed_out: true,
      status: 'timed_out',
      response_mode: 'human',
      human_needed: true,
      error_class: error.class.name,
      operator_note: 'Request timed out; human follow-up required.'
    }
  end

  def playground_params
    params.require(:assistant).permit(
      :message_content,
      :conversation_id,
      :test_model,
      :test_temperature,
      :test_thinking_effort,
      message_history: [:role, :content, :agent_name]
    )
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
