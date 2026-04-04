# frozen_string_literal: true

class Llm::ChatRequestRunner
  attr_reader :context, :model, :messages, :schema, :tools, :params, :chat, :on_end_message, :on_tool_call,
              :on_tool_result, :content_builder

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
  end

  def call
    llm_chat = build_chat

    apply_system_instructions(llm_chat)
    llm_chat.with_schema(schema) if schema
    attach_tools_and_callbacks(llm_chat)

    conversation_messages = normalized_conversation_messages
    return nil if conversation_messages.empty?

    add_conversation_history(llm_chat, conversation_messages[0...-1])
    ask_chat(llm_chat, conversation_messages.last[:content])
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
    history.each do |message|
      llm_message = build_history_message(message)
      next unless llm_message

      chat.add_message(llm_message)
    end
  end

  def message_role(message)
    (message[:role] || message['role']).to_s
  end

  def message_content(message)
    message[:content] || message['content']
  end

  def build_message_content(content)
    return content_builder.call(content) if content_builder

    content
  end

  def ask_chat(chat, content)
    Llm::ChatClient.ask(chat, content)
  end

  def build_history_message(message)
    role = message[:role].to_sym
    params = {
      role: role,
      content: message[:content]
    }

    if role == :assistant && message[:tool_calls].present?
      params[:tool_calls] = build_tool_calls(message[:tool_calls])
      params[:content] = '' if params[:content].blank?
    end

    if role == :tool
      return nil if message[:tool_call_id].blank?

      params[:tool_call_id] = message[:tool_call_id]
    end

    RubyLLM::Message.new(**params)
  end

  def build_tool_calls(tool_calls)
    Array(tool_calls).each_with_object({}) do |tool_call, hash|
      tool_call_id = tool_call[:id] || tool_call['id']
      next if tool_call_id.blank?

      hash[tool_call_id] = RubyLLM::ToolCall.new(
        id: tool_call_id,
        name: tool_call[:name] || tool_call['name'],
        arguments: tool_call[:arguments] || tool_call['arguments'] || {}
      )
    end
  end
end
