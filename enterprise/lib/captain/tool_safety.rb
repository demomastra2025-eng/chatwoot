# frozen_string_literal: true

class Captain::ToolSafety
  class << self
    def check_arguments!(feature:, arguments:, account: nil, preferences: nil)
      Llm::SafetyPolicy.check!(
        feature: feature,
        stage: :tool_arguments,
        content: arguments,
        account: account,
        preferences: preferences
      )
    end

    def check_result!(feature:, result:, account: nil, preferences: nil)
      Llm::SafetyPolicy.check!(
        feature: feature,
        stage: :tool_results,
        content: result,
        account: account,
        preferences: preferences
      )
    end

    def blocked_message(stage:, error:)
      detail =
        case error
        when Llm::SafetyPolicy::UnavailableError
          'because safety policy is unavailable'
        else
          'by safety policy'
        end

      prefix =
        case stage.to_sym
        when :tool_results
          'Tool result blocked'
        else
          'Tool arguments blocked'
        end

      "ERROR: #{prefix} #{detail}"
    end
  end
end
