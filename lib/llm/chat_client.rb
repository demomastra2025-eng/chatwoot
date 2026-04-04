# frozen_string_literal: true

class Llm::ChatClient
  class << self
    def build(**options)
      llm_chat = options[:chat] || build_chat(context: options[:context], model: options[:model])
      llm_chat = llm_chat.with_temperature(options[:temperature]) unless options[:temperature].nil?
      llm_chat = llm_chat.with_params(**options[:params]) if options[:params].present?
      llm_chat = llm_chat.with_headers(**options[:headers]) if options[:headers].present?
      llm_chat
    end

    def ask(chat, content)
      if content.is_a?(RubyLLM::Content)
        attachments = content.attachments.filter_map { |attachment| attachment_source(attachment) }
        return chat.ask(content.text, with: attachments) if attachments.any?

        return chat.ask(content.text)
      end

      chat.ask(content)
    end

    private

    def build_chat(context:, model:)
      return context.chat(model: model) if context

      RubyLLM.chat(model: model)
    end

    def attachment_source(attachment)
      attachment.respond_to?(:source) ? attachment.source.to_s : attachment.to_s
    end
  end
end
