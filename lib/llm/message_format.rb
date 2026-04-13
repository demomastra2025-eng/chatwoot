# frozen_string_literal: true

require 'set'
require 'uri'

module Llm::MessageFormat
  module_function

  def restore_messages(chat, history)
    valid_tool_call_ids = Set.new

    Array(history).each do |message|
      message_params = build_message_params(message, valid_tool_call_ids:)
      next unless message_params

      llm_message = RubyLLM::Message.new(**message_params)
      chat.add_message(llm_message)
      register_tool_calls(valid_tool_call_ids, message_params, llm_message)
    end
  end

  def build_message_params(message, valid_tool_call_ids: nil)
    role = message_role(message)
    return unless %i[user assistant tool].include?(role)
    return if invalid_tool_result?(message, valid_tool_call_ids)
    return unless restorable_message?(message, role)

    params = {
      role: role,
      content: build_content(normalized_content(message, role))
    }

    return if add_tool_payload(params, message, role) == :invalid

    params
  end

  def build_content(content)
    return content if content.is_a?(RubyLLM::Content) || content.is_a?(String) || content.nil?
    return content.to_json if content.is_a?(Hash)
    return build_multimodal_content(content) if content.is_a?(Array)

    content.to_s
  end

  def build_multimodal_content(content_parts)
    text, attachments = extract_text_and_attachments(content_parts)
    return RubyLLM::Content.new(content_parts.to_json) if text.blank? && attachments.blank?

    attachments.any? ? RubyLLM::Content.new(text, attachments) : RubyLLM::Content.new(text)
  end

  def extract_text_and_attachments(content)
    case content
    when RubyLLM::Content
      [content.text.presence, extract_attachment_sources(content.attachments)]
    when Array
      [text_content(content), image_attachments(content)]
    else
      [content, []]
    end
  end

  def serialize_content(content)
    return serialize_ruby_llm_content(content) if content.is_a?(RubyLLM::Content)
    return content.deep_stringify_keys if content.is_a?(Hash)

    content
  end

  def content_empty?(content)
    case content
    when String
      content.strip.empty?
    when Hash, Array
      content.empty?
    when RubyLLM::Content
      content.text.to_s.strip.empty? && content.attachments.blank?
    else
      content.nil?
    end
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

  def image_part_payload(source)
    { type: 'image_url', image_url: { url: source.to_s } }
  end

  def text_part_payload(text)
    { type: 'text', text: text }
  end

  def text_content(content_parts)
    Array(content_parts).filter_map { |part| text_part(part) }.join(' ').presence
  end

  def image_attachments(content_parts)
    Array(content_parts).filter_map do |part|
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

  def serialize_ruby_llm_content(content)
    attachment_parts = extract_attachment_sources(content.attachments).map { |source| image_part_payload(source) }
    return content.text.to_s if attachment_parts.empty?

    parts = []
    parts << text_part_payload(content.text) if content.text.present?
    parts.concat(attachment_parts)
    parts
  end

  def extract_attachment_sources(attachments)
    Array(attachments).filter_map do |attachment|
      source = attachment.respond_to?(:source) ? attachment.source : attachment
      next source.to_s if source.is_a?(URI::Generic)
      next source if source.is_a?(String)

      nil
    end
  end

  def register_tool_calls(valid_tool_call_ids, message_params, llm_message)
    return unless llm_message.role == :assistant
    return unless message_params[:tool_calls]

    valid_tool_call_ids.merge(message_params[:tool_calls].keys)
  end

  def restorable_message?(message, role)
    return true if role == :tool
    return true if message_tool_calls(message).present?

    !content_empty?(message_content(message))
  end

  def invalid_tool_result?(message, valid_tool_call_ids)
    tool_call_id = message_tool_call_id(message)
    return false unless message_role(message) == :tool && tool_call_id
    return false unless valid_tool_call_ids
    return false if valid_tool_call_ids.include?(tool_call_id)

    Rails.logger.warn("[Llm::MessageFormat] Skipping tool message without matching assistant tool_call_id #{tool_call_id}")
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
end
