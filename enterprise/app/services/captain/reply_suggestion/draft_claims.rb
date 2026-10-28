# frozen_string_literal: true

# Checks a suggestion for an unsupported claim that an appointment action was completed now.
# A successful mutation or an approval card in this run supplies the evidence. Otherwise the
# same platform decision question is used by the suggestion and the evaluation harness.
module Captain::ReplySuggestion::DraftClaims
  CRITERIA = {
    'done' => 'The reply says that a booking, cancellation or rescheduling has just been carried out (it is already done now).',
    'not_done' => 'The reply only offers times, asks for details or confirmation, explains rules, says something is prepared ' \
                  'or awaiting confirmation, or mentions an appointment that existed before.'
  }.freeze
  INSTRUCTIONS = 'You check an assistant draft written to a clinic client. ' \
                 'Decide whether the draft claims that an appointment action was completed now.'
  THRESHOLD = 0.5

  module_function

  # :allowed, :done, or :unavailable. An unavailable decision is never deliverable.
  def check(draft:, context:, account:)
    return :allowed if draft.to_s.blank? || evidence?(context)

    completed_now?(draft: draft, account: account) ? :done : :allowed
  rescue Llm::DecisionChain::ExhaustedError
    :unavailable
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][ReplyClaimCheck] failed error_class=#{e.class.name}")
    :unavailable
  end

  def completed_now?(draft:, account:)
    result = Llm::DecisionChain.decide(feature: :reply_claim_check, account: account,
                                       question: { state: { 'draft_reply' => draft.to_s }, criteria: CRITERIA,
                                                   instructions: INSTRUCTIONS })
    probability = result.probabilities.to_h.with_indifferent_access[:done]
    probability = result.choice == 'done' ? result.confidence : 1.0 - result.confidence if probability.nil? && result.confidence
    raise Llm::DecisionChain::ExhaustedError.new(feature: :reply_claim_check, attempts: []) if probability.nil?

    probability.to_f >= THRESHOLD
  end

  def evidence?(context)
    details = context.to_h.with_indifferent_access
    successful = Array(details[:captain_v2_completed_tool_results]).any? do |record|
      item = record.to_h.with_indifferent_access
      item[:success] == true && mutating?(item[:tool_name])
    end
    pending = Array(details[:captain_suggestion_pending_actions]).any? do |card|
      item = card.to_h.with_indifferent_access
      item[:status].to_s.in?(%w[pending pending_operator_approval])
    end
    successful || pending
  end

  def mutating?(name)
    canonical = Captain::Runtime::ToolFailure.canonical_name(name)
    definition = Captain::ToolRegistry.definition_for(canonical)
    definition.present? && Llm::ToolRiskPolicy::MUTATING_RISK_LEVELS.include?(definition.risk_level)
  end
end
