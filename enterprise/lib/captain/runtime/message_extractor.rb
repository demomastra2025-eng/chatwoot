# frozen_string_literal: true

module Captain::Runtime::MessageExtractor
  module_function

  def content_empty?(content)
    Llm::MessageFormat.content_empty?(content)
  end

  def extract_messages(chat, current_agent)
    return [] unless chat.respond_to?(:messages)

    chat.messages.filter_map do |msg|
      case msg.role
      when :user, :assistant
        extract_user_or_assistant_message(msg, current_agent)
      when :tool
        extract_tool_message(msg)
      end
    end
  end

  def extract_user_or_assistant_message(msg, current_agent)
    return nil unless persistable_message?(msg)
    return base_message(msg) unless msg.role == :assistant

    assistant_message(msg, current_agent)
  end
  private_class_method :extract_user_or_assistant_message

  def persistable_message?(msg)
    message_content?(msg) || assistant_tool_calls?(msg)
  end
  private_class_method :persistable_message?

  def base_message(msg)
    {
      role: msg.role,
      content: message_content?(msg) ? Llm::MessageFormat.serialize_content(msg.content) : ''
    }
  end
  private_class_method :base_message

  def assistant_message(msg, current_agent)
    base_message(msg).tap do |message|
      message[:agent_name] = current_agent.name if current_agent
      message[:tool_calls] = msg.tool_calls.values.map(&:to_h) if assistant_tool_calls?(msg)
      add_thinking_payload(message, msg)
    end
  end
  private_class_method :assistant_message

  def add_thinking_payload(message, msg)
    return unless msg.respond_to?(:thinking) && msg.thinking

    message[:thinking] = msg.thinking.text if msg.thinking.text.present?
    message[:thinking_signature] = msg.thinking.signature if msg.thinking.signature.present?
  end
  private_class_method :add_thinking_payload

  def message_content?(msg)
    msg.content && !content_empty?(msg.content)
  end
  private_class_method :message_content?

  def assistant_tool_calls?(msg)
    msg.role == :assistant && msg.tool_call? && msg.tool_calls.present?
  end
  private_class_method :assistant_tool_calls?

  def extract_tool_message(msg)
    return nil unless msg.tool_result?

    {
      role: msg.role,
      content: msg.content,
      tool_call_id: msg.tool_call_id
    }
  end
  private_class_method :extract_tool_message
end
