# frozen_string_literal: true

class Llm::RuntimePolicy
  THINKING_EFFORTS = %w[none low medium high].freeze
  THINKING_BUDGETS = {
    'low' => 2_048,
    'medium' => 4_096,
    'high' => 8_192
  }.freeze

  class << self
    def thinking_options(feature:, model:, account: nil, preferences: nil)
      effort = runtime_preferences(account, preferences)["#{feature}_thinking_effort"].to_s
      return nil if effort.blank? || effort == 'none'
      return nil unless Llm::Models.supports_thinking?(model)

      options = { effort: effort }
      options[:budget] = budget_for(model, effort) if budget_required?(model)
      options
    end

    def moderation_enabled?(feature:, account: nil, preferences: nil)
      ActiveModel::Type::Boolean.new.cast(
        runtime_preferences(account, preferences)["#{feature}_moderation"]
      )
    end

    private

    def runtime_preferences(account, preferences)
      return preferences.to_h.stringify_keys if preferences.present?
      return account.captain_preferences[:runtime].to_h.stringify_keys if account.respond_to?(:captain_preferences)

      {}
    end

    def budget_required?(model)
      Llm::Config.provider_for_model(model) == 'anthropic'
    end

    def budget_for(_model, effort)
      THINKING_BUDGETS.fetch(effort.to_s, THINKING_BUDGETS['medium'])
    end
  end
end
