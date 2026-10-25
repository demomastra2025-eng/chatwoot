# frozen_string_literal: true

# What the run of the agent ended with, as an outcome of the reply suggestion. The rules are evaluated in this order:
#
#   1  the safety check blocked the turn                    human_needed (safety)
#   2  a custom rule of the agent stopped the turn          human_needed (agent_rule)
#   3  an error ended the run                               failed (reason_code from the error class; router_unavailable or
#                                                           council_unavailable when the router could not route the turn)
#   4  the router sent the turn to staff                    human_needed (router): no agent is named as its author
#      the agent answered response_mode human              human_needed (operator_note), failed when the note is blank
#   5  a council without a text for the patient             human_needed when a part needs staff, else no_reply; the note is
#                                                           written from what the council left (its approval cards are kept)
#      the agent answered response_mode suppress           no_reply (operator_note), failed when the note is blank
#   6  a cancelled response, or a handoff                   failed (invalid_output): a suggestion has neither
#   7  an empty reply                                       failed (empty_output)
#   8  otherwise                                            draft; a council that left parts to staff adds the note for the manager
#                                                           (suggestion_meta operator_note)
#
# A text never comes out of an outcome other than draft.
class Captain::ReplySuggestion::AgentOutcomeClassifier
  RUNNER = Captain::Assistant::AgentRunnerService
  PROVIDER_ERROR = RUNNER::PROVIDER_ERROR_RESPONSE
  NON_DELIVERABLE_RESPONSES = %w[conversation_handoff response_cancelled].freeze
  ERROR_CLASS_CODES = {
    'Captain::TechnicalToolFailure' => 'tool_failure',
    'Captain::Runtime::Runner::TechnicalFailure' => 'tool_failure',
    'Captain::Runtime::Runner::ToolLoopStopped' => 'tool_loop',
    'Captain::Runtime::Runner::MaxTurnsExceeded' => 'max_turns',
    'Captain::Assistant::AgentRunnerService::BlankResponseError' => 'empty_output',
    'Captain::Assistant::AgentRunnerService::SemanticOutputError' => 'invalid_output'
  }.freeze
  # The technical failure the runner reports when the router could not decide or the council could not be set up.
  ROUTER_TOOL = 'agent_router'
  DEFAULT_USAGE = { 'prompt_tokens' => 0, 'completion_tokens' => 0, 'total_tokens' => 0 }.freeze
  PROVIDER_ERROR_PREFIXES = %w[RubyLLM:: Faraday:: Llm:: Net:: Timeout:: OpenSSL:: Errno:: SocketError].freeze
  PART_LIMIT = 160

  def initialize(raw_payload, trace_collector:)
    @payload = raw_payload.to_h.with_indifferent_access
    @trace_collector = trace_collector
  end

  def perform
    classify || draft
  end

  private

  attr_reader :payload, :trace_collector

  def classify
    blocked_outcome || failure_outcome || handoff_outcome || council_silent_outcome || suppress_outcome || undeliverable_outcome
  end

  # 1 and 2: a safety stop is a reason for the manager to answer, not an error.
  def blocked_outcome
    return human_needed(I18n.t('captain.reply_suggestion.reasons.safety_blocked'), 'safety') if payload[RUNNER::MODERATION_BLOCKED_KEY] == true
    return if payload[Captain::Safety::CustomRulesRuntime::RESPONSE_KEY].blank?

    rule_reason = payload.dig(Captain::Safety::CustomRulesRuntime::RESPONSE_KEY, 'reason').presence || '—'
    human_needed(I18n.t('captain.reply_suggestion.reasons.agent_rule', reason: rule_reason), 'agent_rule')
  end

  # 3
  def failure_outcome
    return unless payload[:error_class].present? || payload[:response] == PROVIDER_ERROR

    Captain::ReplySuggestion::Outcome.failed(
      error_code_for(payload[:error_class]), error_class: payload[:error_class].presence, detail: payload[:error_message].to_s.truncate(200).presence
    )
  end

  # 4
  def handoff_outcome
    return unless payload[:response_mode] == 'human'
    return router_human_needed if payload[:routing_human] == true

    human_needed(payload[:operator_note], 'agent')
  end

  # The router chose staff for the turn: it is nobody's decision among the agents, so no agent is named.
  def router_human_needed
    Captain::ReplySuggestion::Outcome.human_needed(
      reason: payload[:operator_note], engine: 'agent', reason_source: 'router', agent: nil, pending_actions: [], usage: usage
    )
  end

  # 5: a council that has no text for the patient. Its parts that need staff, its approval cards and its other notes are still
  # the manager's: they are never dropped as an invalid output.
  def council_silent_outcome
    return unless payload[:council_turn] == true && suppressed?

    meta = suggestion_meta
    note = payload[:operator_note].presence || council_note.presence || I18n.t('captain.reply_suggestion.reasons.council_no_text')
    attributes = { reason: note, engine: 'agent', reason_source: 'agent', agent: meta['agent'],
                   pending_actions: Array(meta['pending_actions']), usage: usage }.merge(lead_agent)
    return Captain::ReplySuggestion::Outcome.human_needed(**attributes) if payload[:council_handoff].present?

    Captain::ReplySuggestion::Outcome.no_reply(**attributes)
  end

  # 5
  def suppress_outcome
    return unless suppressed?

    meta = suggestion_meta
    Captain::ReplySuggestion::Outcome.no_reply(
      reason: payload[:operator_note], engine: 'agent', reason_source: 'agent', agent: meta['agent'],
      pending_actions: Array(meta['pending_actions']), usage: usage
    )
  end

  def suppressed?
    payload[:response_mode] == 'suppress' || payload[:response_suppressed]
  end

  # 6 and 7
  def undeliverable_outcome
    if payload[:response_cancelled] || NON_DELIVERABLE_RESPONSES.include?(payload[:response].to_s.strip)
      return Captain::ReplySuggestion::Outcome.failed('invalid_output', detail: 'non_deliverable_response')
    end
    return Captain::ReplySuggestion::Outcome.failed('empty_output') if payload[:response].to_s.strip.blank?

    nil
  end

  # 8
  def draft
    meta = draft_meta
    trace = trace_collector.captain_trace(payload)
    Captain::ReplySuggestion::Outcome.draft(
      message: payload[:response].to_s.strip, engine: 'agent', usage: usage, agent: meta['agent'], captain_trace: trace.presence,
      suggestion_meta: meta.presence, pending_actions: Array(meta['pending_actions']), **lead_agent
    )
  end

  # A council draft that leaves parts to the manager says so above the draft.
  def draft_meta
    note = council_note
    note.present? ? suggestion_meta.merge('operator_note' => note) : suggestion_meta
  end

  # The agent a council leaves the dialog with (see StickyAgent), when it is not the agent the suggestion is attributed to.
  def lead_agent
    payload[:lead_agent_id].present? ? { lead_agent_id: payload[:lead_agent_id].to_i } : {}
  end

  def human_needed(reason, source)
    meta = suggestion_meta
    Captain::ReplySuggestion::Outcome.human_needed(
      reason: reason, engine: 'agent', reason_source: source, agent: meta['agent'], pending_actions: Array(meta['pending_actions']),
      usage: usage
    )
  end

  # What the council left to the manager, one sentence per kind, in the language of the account (the job runs in it): the parts
  # that failed technically or that it could not resolve (they need the manager's own answer), and the parts whose action was
  # prepared without a text for the patient. The parts are the patient's request fragments, as the staff note of a live council
  # names them. Blank when the council left nothing.
  def council_note
    handoff = payload[:council_handoff].to_h.with_indifferent_access
    note = payload[:council_note].to_h.with_indifferent_access
    {
      'council_technical' => handoff[:failed_parts],
      'council_unresolved' => Array(handoff[:parts]) + Array(note[:unanswered]),
      'council_unreported' => note[:unreported]
    }.filter_map do |key, parts|
      text = parts_text(parts)
      I18n.t("captain.reply_suggestion.reasons.#{key}", parts: text) if text.present?
    end.join(' ')
  end

  def parts_text(parts)
    Array(parts).map { |part| part.to_s.squish.first(PART_LIMIT) }.compact_blank.uniq.join('; ')
  end

  def suggestion_meta
    @suggestion_meta ||= trace_collector.suggestion_meta(payload)
  end

  def usage
    payload[:usage].presence || DEFAULT_USAGE
  end

  def error_code_for(error_class)
    name = error_class.to_s
    return router_failure_code if router_failure_code
    return ERROR_CLASS_CODES[name] if ERROR_CLASS_CODES.key?(name)
    return 'provider_error' if PROVIDER_ERROR_PREFIXES.any? { |prefix| name.start_with?(prefix) } || name.blank?

    'agent_error'
  end

  # The router could not route the turn (every decision model and the escalation failed), or the council it chose could not be set
  # up: not a failure of a tool of the agent.
  def router_failure_code
    failure = payload[:technical_failure].to_h.with_indifferent_access
    return unless failure[:tool].to_s == ROUTER_TOOL

    failure[:reason].to_s == 'council_unavailable' ? 'council_unavailable' : 'router_unavailable'
  end
end
