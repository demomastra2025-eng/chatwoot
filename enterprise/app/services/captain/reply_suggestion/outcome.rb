# frozen_string_literal: true

# The outcome of a reply suggestion run, as the service returns it and as the manager is told about it.
#
#   draft         a text for the manager to review and insert (a council may add operator_note to suggestion_meta: a part of the
#                 request that the draft leaves to the manager)
#   no_reply      the agent decided that no reply is needed; reason: why
#   human_needed  only a staff member can answer; reason: why (reason_source router: the router decided it, no agent did)
#   failed        the run did not finish (timeout, provider error ...): there is NO draft, whatever the run had collected
#   cancelled     the manager cancelled it
module Captain::ReplySuggestion::Outcome
  OUTCOMES = %w[draft no_reply human_needed failed cancelled].freeze
  REASON_SOURCES = %w[agent safety agent_rule router].freeze
  # router_unavailable: no decision model (nor the escalation) could choose the agent; council_unavailable: the council the router
  # chose could not be set up.
  FAILURE_CODES = %w[
    timeout provider_error tool_failure tool_loop max_turns invalid_output empty_output agent_unavailable agent_error
    queue_timeout interrupted quota_exceeded api_key_missing disabled internal_error router_unavailable council_unavailable
  ].freeze
  REASON_LIMIT = 500
  # Precondition errors of the task wrapper (Enterprise::Captain::BaseTaskService#perform) that have no outcome key.
  ERROR_CODE_FAILURES = { 401 => 'api_key_missing', 403 => 'disabled', 429 => 'quota_exceeded' }.freeze

  class << self
    def draft(message:, engine:, usage: nil, **extra)
      { outcome: 'draft', message: message, engine: engine, usage: usage, pending_actions: [] }.merge(extra)
    end

    def no_reply(reason:, engine:, reason_source: 'agent', **extra)
      reason_outcome('no_reply', reason, reason_source, engine, extra)
    end

    def human_needed(reason:, engine:, reason_source: 'agent', **extra)
      reason_outcome('human_needed', reason, reason_source, engine, extra)
    end

    # error_class and detail go to llm_events only, never to the manager.
    def failed(reason_code, error_class: nil, detail: nil, **extra)
      { outcome: 'failed', reason_code: reason_code.to_s, error_class: error_class, detail: detail }.merge(extra).compact
    end

    def cancelled(**extra)
      { outcome: 'cancelled' }.merge(extra)
    end

    # The service returns an outcome; the task wrapper returns { error:, error_code: } when a precondition fails.
    def normalize(result)
      return failed('internal_error', detail: 'empty_result') if result.blank?
      return result.symbolize_keys.merge(outcome: result.with_indifferent_access[:outcome].to_s) if outcome?(result)

      failed(failure_code_for_error(result))
    end

    def outcome?(result)
      result.respond_to?(:with_indifferent_access) && OUTCOMES.include?(result.with_indifferent_access[:outcome].to_s)
    end

    # What the manager's UI is given in `result` (SuggestionState#result), keyed by strings.
    def public_result(outcome)
      case outcome[:outcome].to_s
      when 'draft' then draft_result(outcome)
      when 'no_reply', 'human_needed' then reason_result(outcome)
      when 'failed' then { 'reason_code' => outcome[:reason_code].to_s }
      end
    end

    def reason_code(outcome)
      outcome[:reason_code].to_s.presence if outcome[:outcome].to_s == 'failed'
    end

    private

    def reason_outcome(name, reason, reason_source, engine, extra)
      text = reason.to_s.squish.truncate(REASON_LIMIT)
      return failed('invalid_output', detail: 'missing_operator_note') if text.blank?

      { outcome: name, reason: text, reason_source: reason_source.to_s, engine: engine, pending_actions: [] }.merge(extra)
    end

    def failure_code_for_error(result)
      code = result.with_indifferent_access[:error_code]
      ERROR_CODE_FAILURES.fetch(code.to_i, 'disabled')
    end

    # lead_agent_id (a council only): the agent the dialog stays with when the manager uses the draft (see StickyAgent).
    def draft_result(outcome)
      {
        'message' => outcome[:message].to_s,
        'agent' => outcome[:agent],
        'captain_trace' => outcome[:captain_trace],
        'suggestion_meta' => outcome[:suggestion_meta],
        'pending_actions' => Array(outcome[:pending_actions]),
        'follow_up_context' => outcome[:follow_up_context]
      }.merge(outcome[:lead_agent_id].present? ? { 'lead_agent_id' => outcome[:lead_agent_id] } : {})
    end

    def reason_result(outcome)
      {
        'reason' => outcome[:reason].to_s,
        'reason_source' => outcome[:reason_source].to_s,
        'agent' => outcome[:agent],
        'pending_actions' => Array(outcome[:pending_actions])
      }
    end
  end
end
