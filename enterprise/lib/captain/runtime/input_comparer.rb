# frozen_string_literal: true

module Captain::Runtime::InputComparer
  module_function

  def last_message_matches?(chat, input)
    return false unless input && chat.respond_to?(:messages)

    last_message = chat.messages.last
    return false unless last_message&.role == :user

    comparable_content(last_message.content) == comparable_content(input)
  end

  def comparable_content(value)
    case value
    when RubyLLM::Content
      {
        text: value.text.to_s,
        attachments: value.attachments.filter_map { |attachment| attachment_source(attachment) }
      }
    when Array, Hash
      value.to_json
    else
      value.to_s
    end
  end

  def attachment_source(attachment)
    attachment.respond_to?(:source) ? attachment.source.to_s : attachment.to_s
  end
  private_class_method :attachment_source
end
