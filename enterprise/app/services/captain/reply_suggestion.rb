# frozen_string_literal: true

# "Предложить ответ": the reply suggestion runs as a background job (GenerateJob) so that the request returns at once and the
# agent has a budget of one to two minutes. The request state lives in Redis (RequestStore), the run is cancelled and bounded
# through cooperative checkpoints (RunControl), the outcome is one of Outcome::OUTCOMES.
module Captain::ReplySuggestion
  QUEUE_NAME = :captain_suggestions
  DEFAULT_BUDGET_SECONDS = 60
  # A clinic with two or more agents routes every suggestion (Captain::Runtime::DecisionRouter) and may answer it with a council:
  # the run starts with this budget. The parts of a council end in time for the editor (RunControl#for_parts); a turn that the
  # router gives to one agent or to staff keeps the budget of one agent from the decision on (RunControl#shorten!).
  ROUTER_BUDGET_SECONDS = 120
  MIN_BUDGET_SECONDS = 30
  MAX_BUDGET_SECONDS = 180
  # Safety net around a hung HTTP call: the run is cut at budget + grace.
  HARD_GRACE_SECONDS = 15
  # The budget starts when the job starts. The wait in the queue is separate and capped.
  MAX_QUEUE_WAIT_SECONDS = 45
  TTL_SECONDS = 30.minutes.to_i
  ACCOUNT_SLOT_TTL_SECONDS = 300
  CANCEL_CHECK_INTERVAL = 0.3
  PROGRESS_WRITE_INTERVAL = 1.0
  DEFAULT_MAX_ACTIVE_PER_ACCOUNT = 4
  # The next message of the manager after a dismissed suggestion counts as its replacement for this long.
  DISMISSAL_WINDOW_SECONDS = 30.minutes.to_i

  class << self
    # router: the request is routed among two or more agents (CAPTAIN_SUGGESTION_ROUTER_BUDGET_SECONDS, 120 s by default); else
    # CAPTAIN_SUGGESTION_BUDGET_SECONDS (60 s by default).
    def budget_seconds(router: false)
      value = ENV.fetch(router ? 'CAPTAIN_SUGGESTION_ROUTER_BUDGET_SECONDS' : 'CAPTAIN_SUGGESTION_BUDGET_SECONDS', nil).to_s.strip
      default = router ? ROUTER_BUDGET_SECONDS : DEFAULT_BUDGET_SECONDS
      (value.match?(/\A\d+\z/) ? value.to_i : default).clamp(MIN_BUDGET_SECONDS, MAX_BUDGET_SECONDS)
    end

    def max_active_per_account
      ENV.fetch('CAPTAIN_SUGGESTION_MAX_ACTIVE_PER_ACCOUNT', DEFAULT_MAX_ACTIVE_PER_ACCOUNT).to_i.clamp(1, 50)
    end

    # How long the "one run per user and conversation" lock may outlive a lost job (the longer budget of the two).
    def active_lock_ttl_seconds
      [budget_seconds, budget_seconds(router: true)].max + HARD_GRACE_SECONDS + MAX_QUEUE_WAIT_SECONDS + 30
    end
  end
end
