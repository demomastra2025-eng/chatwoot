# frozen_string_literal: true

module Captain::Assistant::RunPayloadHelper
  private

  def build_context(message_history)
    {
      session_id: "#{@assistant.account_id}_#{@conversation&.display_id}",
      conversation_history: normalize_history(message_history),
      state: build_state
    }
  end

  def extract_last_user_message(message_history)
    last_user_msg = message_history.reverse.find { |msg| message_role(msg) == 'user' }
    return '' if last_user_msg.blank?

    content = message_value(last_user_msg, :content)
    return extract_text_from_content(content) unless content.is_a?(Array)

    text, attachments = Captain::OpenAiMessageBuilderService.extract_text_and_attachments(content)
    return text if attachments.blank?

    RubyLLM::Content.new(text, attachments)
  end

  def message_history_without_last_user_message(message_history)
    last_user_index = message_history.rindex { |msg| message_role(msg) == 'user' }
    return message_history if last_user_index.nil?

    message_history.reject.with_index { |_msg, index| index == last_user_index }
  end

  def extract_text_from_content(content)
    return content[:response] || content['response'] || content.to_s if content.is_a?(Hash)
    return content unless content.is_a?(Array)

    content.select { |part| part[:type] == 'text' }.pluck(:text).join(' ')
  end

  def normalize_history(message_history)
    message_history.filter_map do |message|
      role = message_role(message)
      next if role.blank?

      {
        role: role.to_sym,
        content: normalized_message_content(message),
        agent_name: message_value(message, :agent_name),
        tool_calls: message_value(message, :tool_calls),
        tool_call_id: message_value(message, :tool_call_id)
      }.compact
    end
  end

  def normalized_message_content(message)
    content = message_value(message, :content)
    return content if content.is_a?(Array)

    extract_text_from_content(content)
  end

  def message_role(message)
    message_value(message, :role).to_s.presence
  end

  def message_value(message, key)
    message[key] || message[key.to_s]
  end
end
