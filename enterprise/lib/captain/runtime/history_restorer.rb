# frozen_string_literal: true

class Captain::Runtime::HistoryRestorer
  class << self
    def restore(chat, history)
      Llm::MessageFormat.restore_messages(chat, history)
    end

    def build_message_params(message)
      Llm::MessageFormat.build_message_params(message)
    end

    def build_content(content_value)
      Llm::MessageFormat.build_content(content_value)
    end

    private
  end
end
