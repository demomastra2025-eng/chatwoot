# frozen_string_literal: true

require 'timeout'

class Captain::Safety::CustomRulesDecisionEngine < Captain::Safety::CustomRulesStructuredOutputEngine
  def select(model:, rules:, direction:, text:, context:)
    criteria = rules.to_h { |rule| [rule.fetch('id'), rule.fetch('instruction')] }
    criteria[Captain::Safety::CustomRulesConfig::NONE_ID] = 'No configured condition matches the candidate text.'
    response = Timeout.timeout(Llm::FeatureProfile.for(:custom_guardrail, account: @account).timeout_seconds) do
      Llm::Runtime.decide(
        feature: :custom_guardrail, account: @account, model: model,
        input: user_payload(text, context),
        options: { decision_criteria: criteria, decision_instructions: policy_prompt(direction) },
        observability: { operation: 'captain.custom_guardrail', direction: direction }
      )
    end
    { 'rule_id' => response.choice }
  end
end
