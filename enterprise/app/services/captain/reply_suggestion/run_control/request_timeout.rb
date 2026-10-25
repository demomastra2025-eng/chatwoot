# frozen_string_literal: true

# The HTTP calls RubyLLM makes inside a reply suggestion run (an agent turn, a council part, the editor) end with the run. RubyLLM
# retries a failed call (a timeout, a 5xx, a rate limit: max_retries of the connection) inside the same Faraday request, so the
# bound is set by a middleware that sits inside the retry middleware (Middleware) and runs before EACH attempt: the attempt stops
# at once when the run (or the council part) has no time left or was cancelled - the control's checkpoint raises RunAborted or
# PartTimeUp, which Faraday does not retry - and otherwise its timeout is the provider timeout of the connection or the seconds
# left, whichever is shorter. So a call that hangs cannot take its timeout again on every retry. Outside a run (no RunControl on
# the thread) nothing changes. Prepended to RubyLLM::Connection (config/initializers/captain_reply_suggestion.rb).
module Captain::ReplySuggestion::RunControl::RequestTimeout
  MIN_SECONDS = 1
  STAGE = 'llm_request'

  # The timeout of one attempt: the provider timeout or the seconds the control has left (never under MIN_SECONDS).
  def self.bound!(options, control: Captain::ReplySuggestion::RunControl.current)
    return unless control

    left = [control.seconds_left.to_f, MIN_SECONDS].max
    provider = options.timeout
    options.timeout = provider.present? ? [provider.to_f, left].min : left
  end

  # Before each attempt of a request (the first one and every retry).
  class Middleware < Faraday::Middleware
    def call(env)
      control = Captain::ReplySuggestion::RunControl.current
      if control
        control.checkpoint!(STAGE)
        Captain::ReplySuggestion::RunControl::RequestTimeout.bound!(env.request, control: control)
      end
      @app.call(env)
    end
  end

  private

  # Right after the retry middleware, so every attempt of a retried request passes through Middleware.
  def setup_retry(faraday)
    super
    faraday.use Captain::ReplySuggestion::RunControl::RequestTimeout::Middleware
  end
end
