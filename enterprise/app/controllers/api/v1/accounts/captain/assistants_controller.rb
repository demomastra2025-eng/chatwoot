class Api::V1::Accounts::Captain::AssistantsController < Api::V1::Accounts::BaseController
  before_action :current_account
  before_action -> { check_authorization(Captain::Assistant) }

  before_action :set_assistant, only: [:show, :update, :destroy, :playground]

  def index
    @assistants = account_assistants.ordered
  end

  def show; end

  def create
    @assistant = account_assistants.create!(assistant_params)
  end

  def update
    @assistant.update!(assistant_params)
  end

  def destroy
    @assistant.destroy
    head :no_content
  end

  def playground
    response = Captain::Llm::AssistantChatService.new(assistant: @assistant).generate_response(
      additional_message: params[:message_content],
      message_history: message_history
    )

    render json: response
  rescue Rack::Timeout::RequestTimeoutException, Rack::Timeout::RequestTimeoutError => e
    Rails.logger.warn(
      "#{self.class.name} playground timed out for assistant #{@assistant.id}: #{e.class} - #{e.message}"
    )

    render json: { response: nil, timed_out: true }
  end

  def tools
    assistant = Captain::Assistant.new(account: Current.account)
    @tools = assistant.available_agent_tools
  end

  def context_fields
    assistant = params[:assistant_id].present? ? account_assistants.find(params[:assistant_id]) : Captain::Assistant.new(account: Current.account)
    allowed_ids = assistant.allowed_context_field_ids

    @context_fields = assistant.available_context_fields.map do |field|
      field.merge(selected: allowed_ids.include?(field[:id]))
    end
  end

  private

  def set_assistant
    @assistant = account_assistants.find(params[:id])
  end

  def account_assistants
    @account_assistants ||= Captain::Assistant.for_account(Current.account.id)
  end

  def assistant_params
    permitted = params.require(:assistant).permit(:name, :description,
                                                  config: [
                                                    :product_name, :feature_faq, :feature_memory, :feature_citation,
                                                    :welcome_message, :handoff_message, :resolution_message,
                                                    :instructions, :temperature,
                                                    :auto_reply_on_last_incoming,
                                                    :message_collapse_window_seconds, :history_message_limit
                                                  ])

    # Handle array parameters separately to allow partial updates
    permitted[:response_guidelines] = params[:assistant][:response_guidelines] if params[:assistant].key?(:response_guidelines)

    permitted[:guardrails] = params[:assistant][:guardrails] if params[:assistant].key?(:guardrails)

    assistant_config = params.dig(:assistant, :config)
    if assistant_config.respond_to?(:key?) && assistant_config.key?(:context_access)
      context_access = assistant_config[:context_access]
      permitted[:config] ||= {}
      permitted[:config][:context_access] = context_access.respond_to?(:permit!) ? context_access.permit!.to_h : context_access
    end

    permitted
  end

  def playground_params
    params.require(:assistant).permit(:message_content, message_history: [:role, :content])
  end

  def message_history
    (playground_params[:message_history] || []).map { |message| { role: message[:role], content: message[:content] } }
  end
end
