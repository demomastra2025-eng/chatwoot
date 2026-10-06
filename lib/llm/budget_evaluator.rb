# frozen_string_literal: true

class Llm::BudgetEvaluator
  # Retained for interpreting historical monitoring events.
  ERROR_CODE = 'budget_blocked'
  WARNING_CODE = 'budget_warning'

  Decision = Struct.new(:allowed, :reason, :feature, keyword_init: true) do
    def allowed? = allowed == true
    def blocked? = !allowed?
    def warning? = false

    def to_h
      { allowed: allowed?, reason: reason, feature: feature }
    end
  end

  class << self
    def evaluate(request:, **_options)
      # Stored policies are ignored. Spending must never prevent a request.
      Decision.new(allowed: true, reason: 'no_limit', feature: request.feature_key)
    end

    def evaluate!(request:, **)
      evaluate(request: request, **)
    end
  end
end
