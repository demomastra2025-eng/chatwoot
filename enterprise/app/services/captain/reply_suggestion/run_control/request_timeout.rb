# frozen_string_literal: true

# The HTTP calls RubyLLM makes inside a reply suggestion run (an agent turn, a council part, the editor) end with the run: the
# timeout of each request is the provider timeout of the connection or the seconds the run (or the council part) has left,
# whichever is shorter, so an in-flight call cannot overrun the deadline. Outside a run (no RunControl on the thread) nothing
# changes. Prepended to RubyLLM::Connection (config/initializers/captain_reply_suggestion.rb).
module Captain::ReplySuggestion::RunControl::RequestTimeout
  MIN_SECONDS = 1

  def self.bound!(request, control: Captain::ReplySuggestion::RunControl.current)
    return unless control

    left = [control.seconds_left.to_f, MIN_SECONDS].max
    provider = request.options.timeout
    request.options.timeout = provider.present? ? [provider.to_f, left].min : left
  end

  def post(url, payload, &block)
    super(url, payload) do |request|
      block&.call(request)
      Captain::ReplySuggestion::RunControl::RequestTimeout.bound!(request)
    end
  end
end
