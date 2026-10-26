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
#                                                           written from what the council left (its approval cards are kept),
#                                                           or says that no part needed a reply (council_no_reply)
#      the router found that no answer is needed           no_reply (router): no agent ran, so none is named
#      the agent answered response_mode suppress           no_reply (operator_note), failed when the note is blank
#   6  a cancelled response, or a handoff                   failed (invalid_output): a suggestion has neither
#   7  an empty reply                                       failed (empty_output)
#   8  otherwise                                            draft; a council that left parts to staff adds the note for the manager
#                                                           (suggestion_meta operator_note), and so does a draft that names a time
#                                                           its scheduling reads did not find (unverified_times, see DraftTimes)
#                                                           or a draft that leaves a part of the request to staff (the agent's
#                                                           operator_note)
#
# After these rules, a no_reply (the agent's, the router's or a council's) for patient messages that ask to cancel, move or make a visit
# («Отмена завтра», «не смогу прийти», «запишите», «болдырмаңыз», «жазылғым келеді», see Captain::PatientIntent) is turned into
# human_needed with a note of its own: a request is never swallowed by an emoji that came after it.
#
# A text never comes out of an outcome other than draft. An outcome of a turn that the router gave to the anchor only because no
# agent leads the dialog says so (routing_default_to: anchor): its agent does not become the sticky agent (see StickyAgent).
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

  # patient_text: the patient's messages that the run answers (the unanswered ones), for the check of a request that no_reply swallowed.
  def initialize(raw_payload, trace_collector:, patient_text: nil)
    @payload = raw_payload.to_h.with_indifferent_access
    @trace_collector = trace_collector
    @patient_text = patient_text.to_s
  end

  REASONED_OUTCOMES = %w[draft no_reply human_needed].freeze

  def perform
    with_routing_default(unswallowed(classify || draft))
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
    note = payload[:operator_note].presence || council_note.presence || council_silence_reason
    attributes = { reason: note, engine: 'agent', reason_source: 'agent', agent: meta['agent'], **cards_of(meta), usage: usage }
                 .merge(lead_agent)
    return Captain::ReplySuggestion::Outcome.human_needed(**attributes) if payload[:council_handoff].present?

    Captain::ReplySuggestion::Outcome.no_reply(**attributes)
  end

  # Every part of the council answered that it needs no reply (a thanks, an ok), or the council left only its cards.
  def council_silence_reason
    key = payload[:council_no_reply] == true ? 'council_no_reply' : 'council_no_text'
    I18n.t("captain.reply_suggestion.reasons.#{key}")
  end

  # 5
  def suppress_outcome
    return unless suppressed?
    return router_no_reply if payload[:routing_no_reply] == true

    meta = suggestion_meta
    Captain::ReplySuggestion::Outcome.no_reply(
      reason: payload[:operator_note], engine: 'agent', reason_source: 'agent', agent: meta['agent'], **cards_of(meta), usage: usage
    )
  end

  # The router found that the message needs no answer (a plain thanks, ok, goodbye or emoji): no agent ran or proposed anything.
  def router_no_reply
    Captain::ReplySuggestion::Outcome.no_reply(
      reason: payload[:operator_note], engine: 'agent', reason_source: 'router', agent: nil, pending_actions: [], usage: usage
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
      suggestion_meta: meta.presence, **cards_of(meta), **lead_agent
    )
  end

  # The approval cards of the run, and the ids of the cards it withdrew (a corrected card replaced them) for the manager's panel.
  def cards_of(meta)
    superseded = Array(meta['superseded_action_ids'])
    { pending_actions: Array(meta['pending_actions']) }.merge(superseded.any? ? { superseded_action_ids: superseded } : {})
  end

  # A council draft that leaves parts to the manager says so above the draft, and so do a draft of an agent that leaves a part of the
  # request to staff and a draft that names a time the run did not find in its scheduling reads.
  def draft_meta
    note = [agent_draft_note, council_note, unverified_times_note].compact_blank.join(' ')
    meta = unverified_times.any? ? suggestion_meta.merge('unverified_times' => unverified_times) : suggestion_meta
    note.present? ? meta.merge('operator_note' => note) : meta
  end

  def unverified_times
    Array(payload[:unverified_times]).map(&:to_s).compact_blank
  end

  # A draft that answers only a part of the request names the part a staff member must add (the agent's operator_note, see the
  # platform rules of a suggestion): «сколько стоит МРТ поясницы и какая подготовка?» when only staff names that preparation.
  def agent_draft_note
    payload[:operator_note].to_s.squish.presence unless payload[:council_turn]
  end

  def unverified_times_note
    I18n.t('captain.reply_suggestion.reasons.unverified_times', times: unverified_times.join(', ')) if unverified_times.any?
  end

  # The agent a council leaves the dialog with (see StickyAgent), when it is not the agent the suggestion is attributed to.
  def lead_agent
    payload[:lead_agent_id].present? ? { lead_agent_id: payload[:lead_agent_id].to_i } : {}
  end

  def human_needed(reason, source)
    meta = suggestion_meta
    Captain::ReplySuggestion::Outcome.human_needed(
      reason: reason, engine: 'agent', reason_source: source, agent: meta['agent'], **cards_of(meta), usage: usage
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

  # A «no reply» for a message that asks to cancel, move or make a visit swallows the request: the eval of 26.10 answered «Отмена
  # завтра» (followed by an emoji) with «emoji only». Whatever decided it (the agent, the router, a council), the manager is told to
  # answer, and the cards and the agent of the run stay with the note. The words are the check (Captain::PatientIntent).
  def unswallowed(outcome)
    return outcome unless outcome[:outcome].to_s == 'no_reply' && Captain::PatientIntent.booking_change?(@patient_text)

    Captain::ReplySuggestion::Outcome.human_needed(
      reason: I18n.t('captain.reply_suggestion.reasons.swallowed_request'), engine: outcome[:engine],
      reason_source: outcome[:reason_source], **outcome.except(:outcome, :reason, :reason_source, :engine)
    )
  end

  def with_routing_default(outcome)
    return outcome unless REASONED_OUTCOMES.include?(outcome[:outcome].to_s)

    default_to = suggestion_meta.to_h.dig('routing', 'default_to').presence
    default_to ? outcome.merge(routing_default_to: default_to) : outcome
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

  # The router could not route the turn (every decision model failed), or the council it chose could not be set
  # up: not a failure of a tool of the agent.
  def router_failure_code
    failure = payload[:technical_failure].to_h.with_indifferent_access
    return unless failure[:tool].to_s == ROUTER_TOOL

    failure[:reason].to_s == 'council_unavailable' ? 'council_unavailable' : 'router_unavailable'
  end
end
