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
    return unless msg.respond_to?(:thinking) || msg.respond_to?(:reasoning) || msg.respond_to?(:reasoning_details)

    native_reasoning_payload = normalized_native_reasoning_payload(msg)
    native_reasoning = native_reasoning_payload&.dig(:text)
    if msg.respond_to?(:thinking) && msg.thinking
      message[:thinking] = msg.thinking.text if msg.thinking.text.present?
      message[:thinking_signature] = msg.thinking.signature if msg.thinking.signature.present?
    elsif native_reasoning.present?
      message[:thinking] = native_reasoning
    end

    message[:reasoning] = native_reasoning if native_reasoning.present?
    reasoning_details = native_reasoning_details(msg)
    message[:reasoning_details] = reasoning_details if reasoning_details.present?
    message[:native_reasoning] = native_reasoning_payload if native_reasoning_payload.present?
  end
  private_class_method :add_thinking_payload

  def normalized_native_reasoning_payload(msg)
    text = native_reasoning_text(msg) || thinking_text(msg)
    details = native_reasoning_details(msg)
    signature = thinking_signature(msg)
    tokens = reasoning_tokens(msg)
    encrypted = native_reasoning_encrypted?(details)
    return if text.blank? && details.blank? && signature.blank? && tokens.blank? && !encrypted

    {
      source: native_reasoning_source(msg, details),
      text: text,
      summary: text,
      details: details,
      signature: signature,
      tokens: tokens,
      encrypted: (true if encrypted),
      visible_to_user: false
    }.compact
  end
  private_class_method :normalized_native_reasoning_payload

  def native_reasoning_text(msg)
    return unless msg.respond_to?(:reasoning)

    reasoning = msg.reasoning
    return reasoning.to_s.strip.presence if reasoning.is_a?(String) || reasoning.is_a?(Symbol)
    return reasoning[:text].to_s.strip.presence if reasoning.respond_to?(:[]) && reasoning[:text].present?
    return reasoning['text'].to_s.strip.presence if reasoning.respond_to?(:[]) && reasoning['text'].present?

    nil
  rescue StandardError
    nil
  end
  private_class_method :native_reasoning_text

  def native_reasoning_details(msg)
    return unless msg.respond_to?(:reasoning_details)

    details = msg.reasoning_details
    return details if details.is_a?(Array) || details.is_a?(Hash)
    return details.as_json if details.respond_to?(:as_json)
  rescue StandardError
    nil
  end
  private_class_method :native_reasoning_details

  def thinking_text(msg)
    return unless msg.respond_to?(:thinking) && msg.thinking
    return msg.thinking.text if msg.thinking.respond_to?(:text)

    msg.thinking.to_s.strip.presence
  rescue StandardError
    nil
  end
  private_class_method :thinking_text

  def thinking_signature(msg)
    return unless msg.respond_to?(:thinking) && msg.thinking.respond_to?(:signature)

    msg.thinking.signature.presence
  rescue StandardError
    nil
  end
  private_class_method :thinking_signature

  def reasoning_tokens(msg)
    %i[thinking_tokens reasoning_tokens].each do |method_name|
      next unless msg.respond_to?(method_name)

      value = positive_integer(msg.public_send(method_name))
      return value if value.present?
    end

    usage = msg.usage if msg.respond_to?(:usage)
    %i[thinking_tokens reasoning_tokens].each do |method_name|
      next unless usage.respond_to?(method_name)

      value = positive_integer(usage.public_send(method_name))
      return value if value.present?
    end
    nil
  rescue StandardError
    nil
  end
  private_class_method :reasoning_tokens

  def native_reasoning_source(msg, details)
    return 'openrouter' if native_reasoning_text(msg).present? || details.present?

    'rubyllm'
  end
  private_class_method :native_reasoning_source

  def native_reasoning_encrypted?(details)
    Array(details).any? do |detail|
      next false unless detail.respond_to?(:[])

      type = (detail[:type] || detail['type']).to_s
      type.include?('encrypted') || type.include?('redacted')
    end
  end
  private_class_method :native_reasoning_encrypted?

  def positive_integer(value)
    integer = Integer(value)
    integer.positive? ? integer : nil
  rescue ArgumentError, TypeError
    nil
  end
  private_class_method :positive_integer

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
