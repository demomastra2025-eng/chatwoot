# frozen_string_literal: true

require 'json'

# Tells a TECHNICAL tool failure from a BUSINESS outcome. This is the one place that decides it.
#
# Business outcomes are answers the agent can act on: a slot is taken, a slot is unavailable, the patient was not found, an
# argument it can fix by asking or choosing. The agent continues and tells the customer. A technical failure (the provider
# rejected the call or did not answer, a timeout, an unknown outcome, an internal exception, a crashed tool) must never reach
# the customer as text: the run stops and the conversation goes to a human (see Captain::Runtime::ToolWrapper).
#
# The order of the decision, for a failed result:
#   1. The result declares it: error_class 'technical' or 'business' (top level of the result, its audit or its data, as the
#      scheduling tools mark their failures). A declaration always wins.
#   2. No declaration. Only a failure that says it is final (retryable == false) is a candidate for technical: a retryable or
#      unmarked failure is left to the agent, and a loop that keeps failing ends in the loop guards, not here.
#   3. A final failure is still business when the model can fix it: the call was rejected for its arguments or by one of the
#      runtime's own guards, a policy decided (the safety policy blocked a result, the Playground refused a real action), or
#      the result carries a known business reason or code (time_taken, not_found, validation_error ...).
#   4. Everything else is technical.
# A provider write that was sent and awaits its confirmation is neither: it is a pending success.
module Captain::Runtime::ToolFailure
  TECHNICAL = 'technical'
  BUSINESS = 'business'
  DECLARED = [TECHNICAL, BUSINESS].freeze

  SUCCESS = 'success'
  NOT_EXECUTED = 'not_executed'
  UNKNOWN = 'unknown'

  # Failure stages of a call that was rejected before it did anything, for its arguments or by the run's rules.
  MODEL_FIXABLE_STAGES = %w[tool_arguments tool_request validation].freeze
  # Stages in which a policy decided (the result was blocked by the safety policy, the Playground refused a real action). They are
  # no failure of an external system; unlike the stages above, the call itself may have run.
  POLICY_STAGES = %w[tool_results playground_policy].freeze
  # Failure reasons of the runtime's own guards (loop and duplicate guards, argument checks, planning rules): the model
  # misused the tool, no external system failed.
  GUARD_REASONS = %w[
    invalid_tool_arguments duplicate_failed_tool_call mutation_retry_blocked tool_attempt_limit parallel_mutating_tool_call
    service_context_required agent_task_not_active part_plan_required handoff_not_authorized tool_request_limit
    tool_budget_exceeded tool_not_bound
  ].freeze
  # The compact reasons of the scheduling tools that are business outcomes. provider_unavailable, internal_failure and
  # staff_will_help are deliberately absent: they are technical.
  BUSINESS_REASONS = %w[
    time_taken not_found validation_error schedule_not_open invalid_date invalid_date_range invalid_duration
    invalid_service_id unknown_service pending_provider_confirmation
  ].freeze
  PENDING_REASON = 'pending_provider_confirmation'
  # Codes of failures that are answers: a record that is not available to this patient, and the Playground's own policy
  # results (an action waits for the approval of the person who tests, or is not allowed in a test).
  BUSINESS_CODES = %w[
    record_not_available playground_confirmation_required playground_policy_blocked service_context_required tool_budget_exceeded
  ].freeze
  # Writes that only annotate the conversation: they are not an action for the customer.
  ANNOTATION_TOOLS = %w[add_private_note add_contact_note add_label_to_conversation update_priority].freeze
  ENVELOPE_KEYS = %w[error data retryable].freeze

  module_function

  # A hash of facts about a tool result (a success or a failure), all derived from the result alone.
  def describe(result)
    normalized = Captain::ToolResult.normalize(result)
    audit = normalized[:audit].is_a?(Hash) ? normalized[:audit].deep_stringify_keys : {}
    envelope = envelope_of(normalized)
    facts = facts_of(result, normalized, envelope, audit)
    failure = Captain::ToolResult.error?(normalized) || embedded_failure?(parsed_string(result))
    {
      failure: failure,
      declared: declared_class(facts),
      retryable: retryable_of(normalized, envelope),
      stage: facts['failure_stage'].to_s.presence,
      failure_reason: facts['failure_reason'].to_s.downcase.presence,
      reason: facts['reason'].to_s.downcase.presence,
      code: facts['code'].to_s.downcase.presence,
      mutation_executed: audit.key?('mutation_executed') ? audit['mutation_executed'] : facts['mutation_executed'],
      pending: pending_facts?(facts, failure)
    }
  end

  def failure?(result)
    describe(result)[:failure]
  end

  # 'technical', 'business' or nil when the result is not a failure.
  def classify(result)
    info = describe(result)
    return unless info[:failure]
    return info[:declared] if info[:declared]
    return BUSINESS if info[:pending] || info[:retryable] != false
    return BUSINESS if model_fixable?(info) || POLICY_STAGES.include?(info[:stage])

    TECHNICAL
  end

  def technical?(result)
    classify(result) == TECHNICAL
  end

  # Whether the mutation behind a result was performed, for the receipt of an action: success (also a pending one),
  # not_executed (the call was rejected, nothing changed) or unknown (it may or may not have happened).
  def outcome(result)
    info = describe(result)
    return SUCCESS if !info[:failure] || info[:pending]
    return NOT_EXECUTED if info[:mutation_executed] == false || info[:declared] == BUSINESS
    return NOT_EXECUTED if info[:declared].nil? && model_fixable?(info)

    UNKNOWN
  end

  # A provider write was sent and its confirmation follows in a message.
  def pending?(result)
    describe(result)[:pending]
  end

  # A failure that is an answer of the tool itself and changed nothing: the tool declares it business, or it carries a business
  # reason or code (the slot is taken, the patient was not found, the time is outside working hours). The agent acts on it by
  # choosing again or by asking, so a corrected call of the same tool is not a retry of a call that may have gone through. Unlike
  # .outcome, a bare rejection stage without such an answer is not one.
  def business_answer?(result)
    info = describe(result)
    return false unless info[:failure] && !info[:pending]
    return info[:declared] == BUSINESS if info[:declared]

    BUSINESS_REASONS.include?(info[:reason]) || business_code?(info[:code])
  end

  def annotation_tool?(tool_name)
    ANNOTATION_TOOLS.include?(canonical_name(tool_name))
  end

  def canonical_name(tool_name)
    tool_name.to_s.split('__').last.to_s.split(':').last.to_s
  end

  # What the staff note and the events may say about a failed call: names and codes only, never arguments or messages.
  def summary(tool_name, result)
    info = describe(result)
    {
      'tool' => canonical_name(tool_name),
      'kind' => classify(result) || TECHNICAL,
      'stage' => info[:stage],
      'reason' => info[:failure_reason] || info[:reason] || info[:code]
    }.compact
  end

  def model_fixable?(info)
    MODEL_FIXABLE_STAGES.include?(info[:stage]) || GUARD_REASONS.include?(info[:failure_reason]) ||
      BUSINESS_REASONS.include?(info[:reason]) || business_code?(info[:code])
  end

  def business_code?(code)
    code.present? && business_codes.include?(code.to_s.downcase)
  end

  def business_codes
    @business_codes ||= begin
      appointment = Captain::Tools::Agent::AppointmentResult
      scheduling = appointment::CONFLICT_CODES + appointment::NOT_FOUND_CODES + appointment::VALIDATION_CODES +
                   (appointment::INPUT_FAILURE_GUIDANCE.keys - %w[PROVIDER_UNAVAILABLE INTERNAL_FAILURE]) + %w[MEDELEMENT_HORIZON_EXCEEDED]
      (BUSINESS_CODES + scheduling.map(&:downcase)).uniq.freeze
    end
  end

  # A failure that a tool rendered as text ("ERROR: {json}") keeps its structure in that JSON.
  def envelope_of(normalized)
    error = normalized[:error]
    return {} unless error.is_a?(String) && error.start_with?(Captain::ToolResult::ERROR_PREFIX)

    body = error.delete_prefix(Captain::ToolResult::ERROR_PREFIX).strip
    return {} unless body.start_with?('{')

    parsed = JSON.parse(body)
    parsed.is_a?(Hash) ? parsed.deep_stringify_keys : {}
  rescue JSON::ParserError
    {}
  end

  # The facts a result carries, wherever the tool put them. A later source wins over an earlier one.
  def facts_of(result, normalized, envelope, audit)
    sources = [
      envelope['data'], envelope.except(*ENVELOPE_KEYS), parsed_string(result), raw_hash(result), hash_or_empty(normalized[:data]), audit
    ]
    sources.each_with_object({}) { |source, facts| facts.merge!(hash_or_empty(source)) }
  end

  def retryable_of(normalized, envelope)
    return normalized[:retryable] unless normalized[:retryable].nil?

    envelope['retryable']
  end

  def declared_class(facts)
    value = facts['error_class'].to_s.strip.downcase
    DECLARED.include?(value) ? value : nil
  end

  def pending_facts?(facts, failure)
    return facts['reason'].to_s.downcase == PENDING_REASON if failure

    facts['provider_confirmation_required'] == true && facts['provider_confirmed'] != true
  end

  # A failure in the compact form of the scheduling tools that the normalization did not recognise because it carries a key it
  # does not know (error_class). The body of an external API that happens to say success: false is not one: it has no reason.
  def embedded_failure?(parsed)
    parsed['success'] == false && (parsed.key?('reason') || parsed.key?('error_class') || parsed.key?('code'))
  end

  def parsed_string(result)
    return {} unless result.is_a?(String) && result.lstrip.start_with?('{')

    parsed = JSON.parse(result)
    parsed.is_a?(Hash) ? parsed.deep_stringify_keys : {}
  rescue JSON::ParserError
    {}
  end

  # A result hash that the normalization would have reduced to its known keys.
  def raw_hash(result)
    result.is_a?(Hash) ? result.deep_stringify_keys.except(*Captain::ToolResult::NORMALIZED_KEYS.map(&:to_s)) : {}
  end

  def hash_or_empty(value)
    value.is_a?(Hash) ? value.deep_stringify_keys : {}
  end
end
