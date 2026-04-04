# frozen_string_literal: true

class Captain::Runtime::HistoryRestorer
  class << self
    def restore(chat, history)
      valid_tool_call_ids = Set.new

      Array(history).each do |message|
        restore_message(chat, message, valid_tool_call_ids)
      end
    end

    def build_message_params(message)
      role = message_role(message)
      return unless role

      params = {
        role: role,
        content: build_content(normalized_content(message, role))
      }

      return if add_tool_payload(params, message, role) == :invalid

      params
    end

    def build_content(content_value)
      return RubyLLM::Content.new(content_value) unless content_value.is_a?(Array)

      text = text_content(content_value)
      image_urls = image_attachments(content_value)
      return RubyLLM::Content.new(content_value.to_json) if text.empty? && image_urls.empty?

      image_urls.any? ? RubyLLM::Content.new(text, image_urls) : RubyLLM::Content.new(text)
    end

    private

    def restore_message(chat, message, valid_tool_call_ids)
      return unless restorable_message?(message)
      return if invalid_tool_result?(message, valid_tool_call_ids)

      message_params = build_message_params(message)
      return unless message_params

      llm_message = RubyLLM::Message.new(**message_params)
      chat.add_message(llm_message)
      register_tool_calls(valid_tool_call_ids, llm_message, message_params)
    end

    def register_tool_calls(valid_tool_call_ids, llm_message, message_params)
      return unless llm_message.role == :assistant
      return unless message_params[:tool_calls]

      valid_tool_call_ids.merge(message_params[:tool_calls].keys)
    end

    def restorable_message?(message)
      role = message_role(message)
      return false unless %i[user assistant tool].include?(role)
      return true if role == :tool

      return true if message_tool_calls(message).present?

      !Captain::Runtime::MessageExtractor.content_empty?(message_content(message))
    end

    def invalid_tool_result?(message, valid_tool_call_ids)
      tool_call_id = message_tool_call_id(message)
      return false unless message_role(message) == :tool && tool_call_id
      return false if valid_tool_call_ids.include?(tool_call_id)

      Rails.logger.warn("[Captain::Runtime] Skipping tool message without matching assistant tool_call_id #{tool_call_id}")
      true
    end

    def normalized_content(message, role)
      content = message_content(message)
      return content unless role == :assistant && content.nil?
      return '' if message_tool_calls(message).present?

      content
    end

    def add_tool_payload(params, message, role)
      return add_tool_result_payload(params, message) if role == :tool
      return unless role == :assistant && message_tool_calls(message).present?

      params[:tool_calls] = build_tool_calls(message_tool_calls(message))
    end

    def add_tool_result_payload(params, message)
      tool_call_id = message_tool_call_id(message)
      return :invalid if tool_call_id.blank?

      params[:tool_call_id] = tool_call_id
    end

    def build_tool_calls(tool_calls)
      Array(tool_calls).each_with_object({}) do |tool_call, hash|
        tool_call_id = tool_call[:id] || tool_call['id']
        next unless tool_call_id

        hash[tool_call_id] = RubyLLM::ToolCall.new(
          id: tool_call_id,
          name: tool_call[:name] || tool_call['name'],
          arguments: tool_call[:arguments] || tool_call['arguments'] || {}
        )
      end
    end

    def text_content(content_parts)
      content_parts
        .filter_map { |part| text_part(part) }
        .join(' ')
    end

    def image_attachments(content_parts)
      content_parts.filter_map do |part|
        next unless image_part?(part)

        part.dig(:image_url, :url) || part.dig('image_url', 'url')
      end
    end

    def text_part(part)
      return unless text_part?(part)

      part[:text] || part['text']
    end

    def text_part?(part)
      (part[:type] || part['type']) == 'text'
    end

    def image_part?(part)
      (part[:type] || part['type']) == 'image_url'
    end

    def message_role(message)
      role = message[:role] || message['role']
      role&.to_sym
    end

    def message_content(message)
      message[:content] || message['content']
    end

    def message_tool_calls(message)
      message[:tool_calls] || message['tool_calls']
    end

    def message_tool_call_id(message)
      message[:tool_call_id] || message['tool_call_id']
    end
  end
end
