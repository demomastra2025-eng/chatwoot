# frozen_string_literal: true

# Checks a suggestion for unsupported appointment claims against evidence from this run.
module Captain::ReplySuggestion::DraftClaims
  CRITERIA = {
    'done' => 'The reply says that a booking, cancellation or rescheduling has just been carried out (it is already done now).',
    'not_done' => 'The reply only offers times, asks for details or confirmation, explains rules, says something is prepared ' \
                  'or awaiting confirmation, or mentions an appointment that existed before.'
  }.freeze
  INSTRUCTIONS = 'You check an assistant draft written to a clinic client. ' \
                 'Decide whether the draft claims that an appointment action was completed now.'
  NO_APPOINTMENT_CRITERIA = {
    'no_appointment' => 'The draft tells the client they have no appointment or no booking.',
    'other' => 'The draft does not tell the client they have no appointment or no booking.'
  }.freeze
  QUESTIONS = {
    'completed_action' => { criteria: CRITERIA, instructions: INSTRUCTIONS },
    'no_appointment' => { criteria: NO_APPOINTMENT_CRITERIA,
                          instructions: 'Does the draft tell the client they have no appointment or no booking?' }
  }.freeze
  THRESHOLD = 0.5

  module_function

  # :allowed, :done, :no_appointment, or :unavailable. An unavailable decision is never deliverable.
  def check(draft:, context:, account:)
    return :allowed if draft.to_s.blank?

    result = Llm::DecisionChain.decide(feature: :reply_claim_check, account: account,
                                       question: { state: { 'draft_reply' => draft.to_s }, questions: QUESTIONS })
    return :no_appointment if active_future_appointment?(context, account: account) &&
                              probability(result.answers['no_appointment'], 'no_appointment') >= THRESHOLD
    return :done if !evidence?(context) && probability(result.answers['completed_action'], 'done') >= THRESHOLD

    :allowed
  rescue Llm::DecisionChain::ExhaustedError
    :unavailable
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][ReplyClaimCheck] failed error_class=#{e.class.name}")
    :unavailable
  end

  def probability(answer, choice)
    value = answer&.probabilities.to_h.with_indifferent_access[choice]
    value = answer.choice == choice ? answer.confidence : 1.0 - answer.confidence if value.nil? && answer&.confidence
    raise Llm::DecisionChain::ExhaustedError.new(feature: :reply_claim_check, attempts: []) if value.nil?

    value.to_f
  end

  def active_future_appointment?(context, account:)
    appointment_cards(context).any? { |card| future_appointment_card?(card, account) }
  end

  def appointment_cards(context)
    details = context.to_h.with_indifferent_access
    preload = details[:suggestion_preload].to_h.with_indifferent_access
    own = Array(preload[:appointments]).reject { |card| card.to_h.with_indifferent_access[:own] == false }
    own + lookup_appointment_cards(details)
  end

  def lookup_appointment_cards(details)
    details[Captain::Runtime::ToolWrapper::SUGGESTION_READ_CACHE_KEY].to_h.values.flat_map do |entry|
      read = entry.to_h.with_indifferent_access
      next [] unless read[:tool].to_s == 'list_my_appointments'

      payload = read[:result].is_a?(String) ? JSON.parse(read[:result]) : read[:result]
      Array(payload.to_h.with_indifferent_access[:appointments]).reject do |card|
        card.to_h.with_indifferent_access[:patient_name].present?
      end
    rescue JSON::ParserError
      []
    end
  end

  def future_appointment_card?(card, account)
    item = card.to_h.with_indifferent_access
    return false unless item[:status].to_s.in?(%w[scheduled confirmed])

    timezone = ActiveSupport::TimeZone[account.reporting_timezone] if account.reporting_timezone.present?
    timezone ||= Time.zone
    timezone.strptime("#{item[:date]} #{item[:time]}", '%d.%m.%Y %H:%M') > Time.current
  rescue ArgumentError
    false
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
