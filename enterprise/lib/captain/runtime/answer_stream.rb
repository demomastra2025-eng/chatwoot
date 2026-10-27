# frozen_string_literal: true

# The answer of the agent of a reply suggestion, as the model writes it. A reply suggestion has a listener for the pieces of the
# text (the :answer_delta callback, see Captain::ReplySuggestion::DraftStream); the runner then asks the model to stream, and every
# piece of text that arrives is handed to the listener. Streaming changes how the answer arrives, never what it is: the runner gets
# the same complete message at the end, and everything after that (the checks, the outcome) runs on it as before.
#
# Only the agent that answers the manager streams. A live conversation, the playground and a council part do not: there is nobody to
# show the text to, or the text is not the answer (the editor of a council merges the texts of its parts).
module Captain::Runtime::AnswerStream
  EVENT = :answer_delta

  class << self
    def enabled?(context_wrapper)
      context = context_wrapper&.context
      return false unless Captain::Runtime::Runner.reply_suggestion?(context)
      return false if context[:part_run]

      context_wrapper.callback_manager.listening?(EVENT)
    end

    # The block the runtime gives to the model call: it passes the text of each streamed chunk to the listeners. A chunk without
    # text (a piece of a tool call, the usage at the end) says nothing. It never raises into the call it listens to.
    def consumer(agent_name, context_wrapper)
      manager = context_wrapper.callback_manager
      lambda do |chunk|
        text = chunk.respond_to?(:content) ? chunk.content : nil
        manager.emit(EVENT, agent_name, text, context_wrapper) if text.is_a?(String) && text.present?
      rescue StandardError => e
        Rails.logger.warn("[Captain::Runtime] answer stream skipped a chunk: #{e.class}")
      end
    end
  end
end
