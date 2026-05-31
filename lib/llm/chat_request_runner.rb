# frozen_string_literal: true

class Llm::ChatRequestRunner
  attr_reader :context, :model, :messages, :schema, :tools, :params, :headers, :chat, :account, :feature, :temperature, :on_end_message,
              :on_tool_call, :on_tool_result, :content_builder, :observability

  def initialize(messages:, **options)
    @messages = messages
    @context = options[:context]
    @model = options[:model]
    @schema = options[:schema]
    @tools = options[:tools] || []
    @params = options[:params] || {}
    @headers = options[:headers] || {}
    @chat = options[:chat]
    @account = options[:account]
    @feature = options[:feature].presence || observability_feature(options[:observability])
    @temperature = options[:temperature]
    @on_end_message = options[:on_end_message]
    @on_tool_call = options[:on_tool_call]
    @on_tool_result = options[:on_tool_result]
    @content_builder = options[:content_builder]
    @observability = options[:observability]
  end

  def call
    llm_chat = build_chat

    llm_chat = tag_openrouter_routing_metadata(llm_chat)
    llm_chat = apply_system_instructions(llm_chat)
    Llm::CapabilityPolicy.ensure_chat_features_supported!(model: effective_model_name(llm_chat), schema: schema, tools: tools, account: account)
    llm_chat = Llm::StructuredOutputPolicy.bind!(chat: llm_chat, schema: schema) if schema
    llm_chat = enforce_openrouter_tool_parameters!(llm_chat)
    llm_chat = attach_tools_and_callbacks(llm_chat)

    conversation_messages = normalized_conversation_messages
    return nil if conversation_messages.empty?

    run_observed(llm_chat) do
      add_conversation_history(llm_chat, conversation_messages[0...-1])
      ask_chat_with_retries(llm_chat, conversation_messages.last[:content])
    end
  end

  private

  def observability_feature(payload)
    return unless payload.respond_to?(:[])

    payload[:feature] || payload['feature'] || payload[:feature_name] || payload['feature_name']
  end

  def build_chat
    llm_chat = Llm::ChatClient.build(**chat_build_kwargs)
    raise ArgumentError, 'Either chat or context/model must be provided' unless llm_chat

    llm_chat
  end

  def chat_build_kwargs
    {
      context: context,
      model: model,
      params: params,
      headers: headers,
      chat: chat,
      feature: feature,
      temperature: temperature,
      routing_metadata: observability
    }.tap do |kwargs|
      kwargs[:account] = account if account.present?
    end
  end

  def normalized_conversation_messages
    messages.filter_map do |message|
      role = message_role(message)
      next if role == 'system'
      next if role.blank?

      {
        role: role,
        content: build_message_content(message_content(message)),
        tool_calls: message[:tool_calls] || message['tool_calls'],
        tool_call_id: message[:tool_call_id] || message['tool_call_id']
      }
    end
  end

  def apply_system_instructions(chat)
    system_messages = messages.filter_map do |message|
      next unless message_role(message) == 'system'

      message_content(message)
    end
    return chat if system_messages.blank?

    chat.with_instructions(system_messages.join("\n\n"))
  end

  def attach_tools_and_callbacks(chat)
    tools.each { |tool| chat = chained_chat(chat.with_tool(tool), chat) }

    if on_end_message
      callback_chat = chat
      chat = chained_chat(
        chat.on_end_message { |message| on_end_message.call(callback_chat, message) },
        chat
      )
    end
    chat = chained_chat(chat.on_tool_call { |tool_call| on_tool_call.call(tool_call) }, chat) if on_tool_call
    chat = chained_chat(chat.on_tool_result { |result| on_tool_result.call(result) }, chat) if on_tool_result
    chat
  end

  def chained_chat(candidate, fallback)
    return candidate if candidate.respond_to?(:ask)

    fallback
  end

  def enforce_openrouter_tool_parameters!(chat)
    return chat if tools.blank?

    Llm::OpenRouterRequestPolicy.require_parameters!(
      chat,
      account: account,
      feature: feature,
      model: effective_model_name(chat),
      tools: true,
      schema: schema.present?
    )
  end

  def tag_openrouter_routing_metadata(chat)
    Llm::OpenRouterRequestPolicy.tag!(
      chat,
      feature: feature,
      account: account,
      model: effective_model_name(chat),
      routing_metadata: observability
    )
  end

  def add_conversation_history(chat, history)
    Llm::MessageFormat.restore_messages(chat, history)
  end

  def message_role(message)
    (message[:role] || message['role']).to_s
  end

  def message_content(message)
    message[:content] || message['content']
  end

  def build_message_content(content)
    return content_builder.call(content) if content_builder

    Llm::MessageFormat.build_content(content)
  end

  def ask_chat(chat, content)
    kwargs = { model: effective_model_name(chat) }
    kwargs[:account] = account if account.present?

    Llm::ChatClient.ask(chat, content, **kwargs)
  end

  def ask_chat_with_retries(chat, content)
    policy = retry_policy(chat)
    attempt = 0

    loop do
      attempt += 1
      message_count_before_attempt = chat_message_count(chat)

      begin
        response = ask_chat(chat, content)
        decision = policy.retryable_response?(response, attempt: attempt)
        return response unless decision.retryable?

        restore_chat_messages!(chat, message_count_before_attempt)
        publish_retry_event(chat, decision, attempt)
      rescue StandardError => e
        decision = policy.retryable_error?(e, attempt: attempt)
        raise unless decision.retryable?

        restore_chat_messages!(chat, message_count_before_attempt)
        publish_retry_event(chat, decision, attempt, error: e)
      end
    end
  end

  def retry_policy(chat)
    Llm::OpenRouterRetryPolicy.new(
      provider: provider_for_retry(chat),
      model: effective_model_name(chat),
      feature: feature,
      account: account,
      tools: tools,
      stream: params[:stream] || params['stream']
    )
  end

  def provider_for_retry(chat)
    chat_model = chat.respond_to?(:model) ? chat.model : nil
    return chat_model.provider if chat_model.respond_to?(:provider)

    Llm::Models.provider_for(effective_model_name(chat), account: account)
  rescue StandardError
    nil
  end

  def chat_message_count(chat)
    return unless chat.respond_to?(:messages)
    return unless chat.messages.is_a?(Array)

    chat.messages.length
  end

  def restore_chat_messages!(chat, message_count)
    return if message_count.nil?
    return unless chat.respond_to?(:messages)
    return unless chat.messages.is_a?(Array)

    chat.messages.pop while chat.messages.length > message_count
  end

  def publish_retry_event(chat, decision, attempt, error: nil)
    payload = observability_payload(chat).merge(
      status: 'retrying',
      error: error.present?,
      reason: decision.reason,
      openrouter_error_category: decision.category,
      retry_after_seconds: decision.retry_after_seconds,
      attempt: attempt,
      max_attempts: decision.max_attempts,
      retry_count: attempt,
      provider: 'openrouter'
    ).compact
    payload[:error_class] = error.class.name if error
    payload[:error_message] = Llm::ObservabilityPayload.sanitize_error_message(error) if error

    Llm::EventBus.publish('run.retry', payload)
  end

  def run_observed(chat)
    payload = observability_payload(chat)
    return yield if payload.blank?

    Llm::EventBus.publish('chat.complete', payload) do |event_payload|
      response = yield
      Llm::ObservabilityPayload.attach_chat_response!(event_payload, response)
      response
    rescue StandardError => e
      Llm::ObservabilityPayload.attach_error!(event_payload, e)
      raise
    end
  end

  def observability_payload(chat)
    return {} if observability.blank?

    payload = Llm::ObservabilityPayload.normalize(
      observability,
      model: effective_model_name(chat),
      runtime_mode: 'chat_request_runner'
    )
    payload[:schema_name] ||= schema_name if schema.present?
    payload[:tool_count] = tools.size if tools.present?
    payload
  end

  def schema_name
    return schema.name if schema.respond_to?(:name) && schema.name.present?

    schema.class.name
  end

  def effective_model_name(chat)
    return model if model.present?
    return unless chat.respond_to?(:model)

    chat_model = chat.model
    return chat_model.id if chat_model.respond_to?(:id)
    return chat_model if chat_model.present?
  end
end
