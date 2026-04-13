# frozen_string_literal: true

class Llm::ChatRequestRunner
  attr_reader :context, :model, :messages, :schema, :tools, :params, :chat, :on_end_message, :on_tool_call,
              :on_tool_result, :content_builder, :observability

  def initialize(messages:, **options)
    @messages = messages
    @context = options[:context]
    @model = options[:model]
    @schema = options[:schema]
    @tools = options[:tools] || []
    @params = options[:params] || {}
    @chat = options[:chat]
    @on_end_message = options[:on_end_message]
    @on_tool_call = options[:on_tool_call]
    @on_tool_result = options[:on_tool_result]
    @content_builder = options[:content_builder]
    @observability = options[:observability]
  end

  def call
    llm_chat = build_chat

    apply_system_instructions(llm_chat)
    Llm::CapabilityPolicy.ensure_chat_features_supported!(model: effective_model_name(llm_chat), schema:, tools:)
    Llm::StructuredOutputPolicy.bind!(chat: llm_chat, schema:) if schema
    attach_tools_and_callbacks(llm_chat)

    conversation_messages = normalized_conversation_messages
    return nil if conversation_messages.empty?

    run_observed(llm_chat) do
      add_conversation_history(llm_chat, conversation_messages[0...-1])
      ask_chat(llm_chat, conversation_messages.last[:content])
    end
  end

  private

  def build_chat
    llm_chat = Llm::ChatClient.build(context: context, model: model, params: params, chat: chat)
    raise ArgumentError, 'Either chat or context/model must be provided' unless llm_chat

    llm_chat
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
    return if system_messages.blank?

    chat.with_instructions(system_messages.join("\n\n"))
  end

  def attach_tools_and_callbacks(chat)
    tools.each { |tool| chat.with_tool(tool) }

    chat.on_end_message { |message| on_end_message.call(chat, message) } if on_end_message
    chat.on_tool_call { |tool_call| on_tool_call.call(tool_call) } if on_tool_call
    chat.on_tool_result { |result| on_tool_result.call(result) } if on_tool_result
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
    Llm::ChatClient.ask(chat, content, model: effective_model_name(chat))
  end

  def run_observed(chat)
    payload = observability_payload(chat)
    return yield if payload.blank?

    Llm::EventBus.publish('chat.complete', payload) do |event_payload|
      begin
        response = yield
        Llm::ObservabilityPayload.attach_chat_response!(event_payload, response)
        response
      rescue StandardError => e
        Llm::ObservabilityPayload.attach_error!(event_payload, e)
        raise
      end
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
    chat_model = chat&.model
    return chat_model.id if chat_model.respond_to?(:id)
    return chat_model if chat_model.present?

    model
  end
end
