class Api::V1::Accounts::Captain::AssistantsController < Api::V1::Accounts::BaseController
  ASSISTANT_CONFIG_FIELDS = [
    :feature_faq, :feature_memory, :feature_citation,
    :welcome_message, :handoff_message, :resolution_message,
    :temperature,
    :auto_reply_on_last_incoming,
    :message_collapse_window_seconds, :history_message_limit
  ].freeze

  before_action :current_account
  before_action -> { check_authorization(Captain::Assistant) }

  before_action :set_assistant, only: [:show, :update, :destroy, :playground, :avatar, :prompt_preview]

  def index
    @assistants = account_assistants.ordered
  end

  def show; end

  def create
    @assistant = account_assistants.create!(assistant_params)
  end

  def update
    @assistant.update!(assistant_update_params)
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
    response = Captain::Assistant::AgentRunnerService.new(
      assistant: @assistant,
      source: 'playground'
    ).generate_response(
      message_history: playground_message_history
    )

    render json: response
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

  def context_fields
    assistant = params[:assistant_id].present? ? account_assistants.find(params[:assistant_id]) : Captain::Assistant.new(account: Current.account)
    allowed_ids = assistant.selected_context_field_ids

    @context_fields = assistant.available_context_fields.map do |field|
      field.merge(selected: allowed_ids.include?(field[:id]))
    end
  end

  private

  def set_assistant
    @assistant = account_assistants.find(params[:id])
  end

  def account_assistants
    @account_assistants ||= Captain::Assistant.for_account(Current.account.id).with_attached_avatar
  end

  def assistant_params
    permitted = params.require(:assistant).permit(
      :name,
      :description,
      :usage_mode,
      config: ASSISTANT_CONFIG_FIELDS
    )

    merge_optional_array_param!(permitted, :response_guidelines)
    merge_optional_array_param!(permitted, :guardrails)
    merge_optional_config_param!(permitted, :context_access)
    merge_optional_config_param!(permitted, :tool_access)
    merge_optional_config_param!(permitted, :rules)

    permitted
  end

  def assistant_update_params
    attributes = assistant_params.to_h.deep_symbolize_keys
    return attributes unless attributes.key?(:config)

    existing_config = @assistant.config.is_a?(Hash) ? @assistant.config.deep_stringify_keys : {}
    incoming_config = attributes[:config].is_a?(Hash) ? attributes[:config].deep_stringify_keys : {}

    attributes.merge(config: existing_config.merge(incoming_config))
  end

  def merge_optional_array_param!(permitted, field_name)
    return unless params[:assistant].key?(field_name)

    permitted[field_name] = params[:assistant][field_name]
  end

  def merge_optional_config_param!(permitted, field_name)
    assistant_config = params.dig(:assistant, :config)
    return unless assistant_config.respond_to?(:key?) && assistant_config.key?(field_name)

    raw_value = assistant_config[field_name]
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
    params.require(:assistant).permit(:message_content, message_history: [:role, :content, :agent_name])
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
