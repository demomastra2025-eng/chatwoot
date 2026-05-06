require 'securerandom'

class Captain::BaseTaskService
  include Integrations::LlmInstrumentation
  include Captain::ToolInstrumentation
  include Llm::ExceptionTrackable

  # gpt-4o-mini supports 128,000 tokens
  # 1 token is approx 4 characters
  # sticking with 120000 to be safe
  # 120000 * 4 = 480,000 characters (rounding off downwards to 400,000 to be safe)
  TOKEN_LIMIT = 400_000
  GPT_MODEL = Llm::Config::DEFAULT_MODEL

  # Prepend enterprise module to subclasses when they're defined.
  # This ensures the enterprise perform wrapper is applied even when
  # subclasses define their own perform method, since prepend puts
  # the module before the class in the ancestor chain.
  def self.inherited(subclass)
    super
    subclass.prepend_mod_with('Captain::BaseTaskService')
  end

  pattr_initialize [:account!, { conversation_display_id: nil }]

  private

  def event_name
    raise NotImplementedError, "#{self.class} must implement #event_name"
  end

  def conversation
    @conversation ||= account.conversations.find_by(display_id: conversation_display_id)
  end

  def make_api_call(model:, messages:, schema: nil, tools: [])
    Llm::Config.initialize!

    # Community edition prerequisite checks
    # Enterprise module handles these with more specific error messages (cloud vs self-hosted)
    return { error: I18n.t('captain.disabled'), error_code: 403 } unless captain_tasks_enabled?
    return { error: I18n.t('captain.api_key_missing'), error_code: 401 } unless api_key_configured?

    Llm::EventBus.with_context(request_event_context(model)) do
      blocked_response = moderate_task_input(messages)
      return blocked_response if blocked_response

      instrumentation_params = build_instrumentation_params(model, messages)
      instrumentation_method = tools.any? ? :instrument_tool_session : :instrument_llm_call

      response = send(instrumentation_method, instrumentation_params) do
        execute_ruby_llm_request(model: model, messages: messages, schema: schema, tools: tools)
      end

      return response if response[:error]

      blocked_response = moderate_task_output(response[:message], messages)
      return blocked_response if blocked_response

      return response unless build_follow_up_context? && response[:message].present?

      response.merge(follow_up_context: build_follow_up_context(messages, response))
    end
  end

  def execute_ruby_llm_request(model:, messages:, schema: nil, tools: [])
    credential = llm_credential
    response = Llm::ChatRequestRunner.new(
      context: llm_context_for(model),
      model: model,
      messages: messages,
      schema: schema,
      tools: tools,
      account: account,
      on_end_message: build_generation_callback(model, tools),
      observability: chat_observability_payload(model)
    ).call

    return { error: 'No conversation messages provided', error_code: 400, request_messages: messages } if response.nil?

    build_ruby_llm_response(response, messages)
  rescue StandardError => e
    capture_llm_exception(e, credential: credential)
    { error: e.message, request_messages: messages }
  end

  def build_generation_callback(model, tools)
    return nil if tools.blank?

    lambda do |chat, message|
      record_generation(chat, message, model)
    end
  end

  def chat_observability_payload(model)
    {
      feature: event_name,
      runtime_mode: 'captain_task',
      account_id: account.id,
      conversation_record_id: conversation&.id,
      conversation_display_id: conversation&.display_id,
      session_id: task_session_id,
      channel_type: conversation&.inbox&.channel_type,
      model: model
    }.compact
  end

  def request_event_context(model)
    chat_observability_payload(model).merge(request_id: SecureRandom.uuid)
  end

  def task_session_id
    return unless conversation_display_id.present?

    "#{account.id}_#{conversation_display_id}"
  end

  def build_ruby_llm_response(response, messages)
    {
      message: response.content,
      usage: {
        'prompt_tokens' => response.input_tokens,
        'completion_tokens' => response.output_tokens,
        'total_tokens' => (response.input_tokens || 0) + (response.output_tokens || 0)
      },
      request_messages: messages
    }
  end

  def build_instrumentation_params(model, messages)
    {
      span_name: "llm.#{event_name}",
      account_id: account.id,
      conversation_id: conversation&.display_id,
      feature_name: event_name,
      model: model,
      messages: messages,
      temperature: nil,
      metadata: instrumentation_metadata
    }
  end

  def moderate_task_input(messages)
    return unless task_moderation_stages.include?(:input)

    input_content = task_input_content(messages)
    return if input_content.blank?

    Llm::SafetyPolicy.check!(
      feature: safety_feature,
      stage: :input,
      content: input_content,
      account: account,
      preferences: task_moderation_preferences
    )
    nil
  rescue Llm::SafetyPolicy::UnsafeContentError
    blocked_task_response('Task input blocked by moderation policy', messages)
  rescue Llm::SafetyPolicy::UnavailableError
    blocked_task_response('Task input blocked because moderation policy is unavailable', messages)
  end

  def moderate_task_output(content, messages)
    return unless task_moderation_stages.include?(:output)
    return if content.blank?

    Llm::SafetyPolicy.check!(
      feature: safety_feature,
      stage: :output,
      content: content,
      account: account,
      preferences: task_moderation_preferences
    )
    nil
  rescue Llm::SafetyPolicy::UnsafeContentError
    blocked_task_response('Task output blocked by moderation policy', messages)
  rescue Llm::SafetyPolicy::UnavailableError
    blocked_task_response('Task output blocked because moderation policy is unavailable', messages)
  end

  def blocked_task_response(message, messages)
    {
      error: message,
      error_code: 422,
      request_messages: messages
    }
  end

  def task_input_content(messages)
    Array(messages).filter_map do |message|
      payload = message.respond_to?(:with_indifferent_access) ? message.with_indifferent_access : message
      payload[:content].presence if payload[:role].to_s == 'user'
    end.join("\n\n").presence
  end

  def safety_feature
    llm_feature_key.to_sym
  end

  def task_moderation_stages
    []
  end

  def task_moderation_preferences
    runtime_preferences = account.respond_to?(:captain_preferences) ? account.captain_preferences[:runtime].to_h.stringify_keys : {}
    runtime_preferences.merge("#{safety_feature}_moderation" => true)
  end

  def instrumentation_metadata
    {
      channel_type: conversation&.inbox&.channel_type
    }.compact
  end

  def conversation_messages(start_from: 0)
    messages = []
    character_count = start_from

    conversation.messages
                .where(message_type: [:incoming, :outgoing])
                .where(private: false)
                .reorder('id desc')
                .each do |message|
      content = message.content_for_llm
      next if content.blank?
      break if character_count + content.length > TOKEN_LIMIT

      messages.prepend({ role: (message.incoming? ? 'user' : 'assistant'), content: content })
      character_count += content.length
    end

    messages
  end

  def captain_tasks_enabled?
    account.feature_enabled?('captain_tasks')
  end

  def api_key_configured?
    api_key(model_provider(task_model)).present?
  end

  def system_api_key(provider_name = 'openai')
    Llm::Config.api_key(provider_name)
  end

  def api_key(provider_name = model_provider)
    Llm::Config.api_key(provider_name, account: account)
  end

  def llm_credential
    provider_name = model_provider(task_model)
    key = api_key(provider_name)
    return if key.blank?

    {
      api_key: key,
      source: Llm::Config.account_provider_available?(provider_name, account: account) ? :account : :system,
      provider: provider_name
    }
  end

  def task_model
    Llm::Config.model_for(
      feature: llm_feature_key,
      account: account,
      fallback: GPT_MODEL
    )
  end

  def llm_feature_key
    'editor'
  end

  def exception_tracking_account
    account
  end

  def prompt_from_file(file_name)
    Captain::PromptRegistry.fetch_task!(file_name)
  end

  def render_task_prompt(file_name, variables = {})
    return prompt_from_file(file_name) if variables.blank?

    Captain::PromptRegistry.render!(file_name, category: :tasks, variables: variables)
  end

  # Follow-up context for client-side refinement
  def build_follow_up_context?
    # FollowUpService should return its own updated context
    !is_a?(Captain::FollowUpService)
  end

  def build_follow_up_context(messages, response)
    {
      event_name: event_name,
      original_context: extract_original_context(messages),
      last_response: response[:message],
      conversation_history: [],
      channel_type: conversation&.inbox&.channel_type
    }
  end

  def extract_original_context(messages)
    # Get the most recent user message for follow-up context
    user_msg = messages.reverse.find { |m| m[:role] == 'user' }
    user_msg ? user_msg[:content] : nil
  end

  def llm_context_for(model)
    provider_name = model_provider(model)
    runtime_api_key = api_key(provider_name)
    runtime_api_base = Llm::Config.api_base(provider_name, account: account)
    return nil if runtime_api_key.blank? && runtime_api_base.blank?

    Llm::Config.context(
      model: model,
      api_key: runtime_api_key,
      api_base: runtime_api_base,
      provider: provider_name,
      account: account
    )
  end

  def model_provider(model = task_model)
    Llm::Config.provider_for_model(model, account: account)
  end
end
Captain::BaseTaskService.prepend_mod_with('Captain::BaseTaskService')
