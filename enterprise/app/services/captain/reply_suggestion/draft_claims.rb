# frozen_string_literal: true

# A reply suggestion may say that a visit is cancelled or moved only when the run called the tool that does it (the card waits for the
# operator, see Captain::ReplySuggestion::ActionApprovalService), and never that the patient has no appointment or that there is
# nothing to cancel: its lookups cover the visits booked from the chat only (suggestion eval 27.10: the drafts of c76-1231671,
# c43-1220644, c77-1221272, c78-1218989 and c76-1246839 told a patient that there was nothing to cancel, or that a visit was cancelled
# when no cancellation was made). The platform rules say so to the model; this checks the draft by its words, as DraftTimes checks the
# times, and names the claim to the manager above the draft. The draft is never changed: the manager decides.
#
# The claims are read by the detector of the benchmark (Captain::Evals::RoutingBenchmark::SuccessClaims: «отменена», «перенесла»,
# «болдырылды», with the questions, the offers, the futures and the negations left out); a claim is supported by a successful or
# pending call of the tool that does it in the run (cancel_appointment, update_appointment), and a state («запись отменена») also by a
# read of the appointments. An absence claim has no support: the rules forbid it whatever the lookups returned.
module Captain::ReplySuggestion::DraftClaims
  CANCELLED = 'cancelled'
  MOVED = 'moved'
  ABSENT = 'no_appointment'
  KINDS = [CANCELLED, MOVED, ABSENT].freeze
  CLAIM_KINDS = { cancel: CANCELLED, cancel_state: CANCELLED, reschedule: MOVED, reschedule_state: MOVED }.freeze
  SUPPORT = {
    cancel: %w[cancel_appointment],
    cancel_state: %w[cancel_appointment list_my_appointments get_appointment search_appointments],
    reschedule: %w[update_appointment],
    reschedule_state: %w[update_appointment]
  }.freeze
  # «нет записи», «у вас нет предстоящих записей», «записей нет», «запись не найдена», «не нашла вашу запись», «нечего отменять»,
  # «ничего не записано», «отменять нечего», «жазба жоқ», «жазылмағансыз». The Kazakh letters are written as typed.
  ABSENCE = Regexp.union(
    /(?<![[:alpha:]])нет\s+(?:у\s+вас\s+)?(?:никаких\s+|активных\s+|действующих\s+|предстоящих\s+|такой\s+|вашей\s+)?(?:записи|записей|брони)/i,
    /(?<![[:alpha:]])(?:записи|записей|брони)\s+(?:у\s+вас\s+)?нет(?![[:alpha:]])/i,
    /(?<![[:alpha:]])запис[ьи]\s+(?:вашей\s+|такой\s+)?не\s+(?:найден|обнаружен)/i,
    /(?<![[:alpha:]])не\s+(?:нашл[аи]?|нашёл|нашел|обнаружил[аи]?)\s+(?:вашу\s+|никакой\s+|ни\s+одной\s+)?запис/i,
    /(?<![[:alpha:]])нечего\s+отмен/i,
    /(?<![[:alpha:]])отмен(?:ять|ить)\s+нечего/i,
    /(?<![[:alpha:]])ничего\s+не\s+записано/i,
    /(?<![[:alpha:]])(?:жазба|жазылу|брон)\s+жоқ/i,
    /(?<![[:alpha:]])жазылмағансыз/i
  )

  module_function

  # The claims of the draft that nothing in the run supports: any of KINDS; empty when the draft claims nothing unsupported.
  def unsupported(draft:, context:)
    text = draft.to_s
    return [] if text.blank?

    tools = called_tools(context.to_h)
    found = Captain::Evals::RoutingBenchmark::SuccessClaims.claims(text).filter_map do |kind, _sentence|
      CLAIM_KINDS[kind] if CLAIM_KINDS.key?(kind) && !SUPPORT.fetch(kind).intersect?(tools)
    end
    found << ABSENT if text.match?(ABSENCE)
    found.uniq
  end

  # The names of the tools the run called (the platform's canonical names), whatever their result was: a cancellation that waits for
  # the operator is a call. The actions that earlier replies of the conversation did (Captain::DoneActions) count too: a draft may report
  # a card of an earlier reply.
  def called_tools(context)
    names = context.key?(:captain_v2_completed_tool_names) ? context[:captain_v2_completed_tool_names] : context['captain_v2_completed_tool_names']
    earlier = Array(context.key?(:done_actions) ? context[:done_actions] : context['done_actions']).map { |entry| entry.to_h.stringify_keys['tool'] }
    (Array(names) + earlier).compact_blank.map { |name| Captain::Runtime::ToolFailure.canonical_name(name) }.uniq
  end
end
