# frozen_string_literal: true

# Scores one customer turn. A Scorer instance belongs to one dialogue: it remembers the successful tool calls and
# the language of the earlier turns, so a follow-up that restates a confirmed operation is not a false claim.
class Captain::Evals::RoutingBenchmark::Scorer
  OPERATION_MODELS = {
    'appointment' => Scheduling::Appointment,
    'deal' => Crm::Deal,
    'contact' => Contact
  }.freeze
  MUTATION_TOOLS = %w[create_appointment update_appointment cancel_appointment create_deal update_deal transition_deal_stage].freeze
  CYRILLIC = /\p{Cyrillic}/
  # The council signal is this persisted event (Captain::Runtime::CoordinationEvents.council_started).
  COUNCIL_STARTED = 'captain.council.started'
  # Failure reasons about the council signal; kept apart from routing reasons such as wrong_agent.
  COUNCIL_REASONS = %w[council_event_missing council_unexpected].freeze

  def initialize(account:, conversation:, internal_texts: [])
    @account, @conversation = account, conversation
    @internal_texts = internal_texts
    @earlier_successes = []
    @language = nil
  end

  def call(turn:, response:, events:, before:)
    expected = turn.fetch('expect')
    tool_events = events.select { |event| event.event_name == 'llm.tool.complete' }
    tools = tool_events.map(&:tool_name)
    acting_agent = Captain::Assistant.where(account_id: @account.id, id: response['agent_id']).pick(:name)
    council = events.any? { |event| event.event_name == COUNCIL_STARTED }
    evidence = collect_evidence(turn, response, tool_events, before)
    counters = hard_zero_counters(evidence, tool_events, response)
    failures = expectation_failures(expected, response, acting_agent: acting_agent, council: council, tools: tools, before: before)
    counters.each { |name, count| failures << name if count.positive? }
    remember_successes(tool_events)
    { status: failures.empty? ? 'pass' : 'fail', reasons: failures, acting_agent: acting_agent, council: council,
      council_expected: expected['council'], tools: tools, hard_zero: counters, operations_ledger: ledger_summary, evidence: evidence }
  end

  private

  def expectation_failures(expected, response, acting_agent:, council:, tools:, before:)
    failures = []
    failures << 'runtime_error' if response['captain_request_id'].blank? ||
                                   response['response'].to_s == Captain::Assistant::AgentRunnerService::PROVIDER_ERROR_RESPONSE
    failures << 'wrong_agent' unless Array(expected['agents'] || expected['agent']).include?(acting_agent)
    failures.concat(council_failures(expected['council'], council))
    Array(expected['must_call']).each { |name| failures << "missing_tool:#{name}" unless tools.include?(name) }
    Array(expected['must_not_call']).each { |name| failures << "forbidden_tool:#{name}" if tools.include?(name) }
    Array(expected['operations']).each do |operation|
      failures << "missing_operation:#{operation['model']}" unless operation_present?(operation, before)
    end
    failures
  end

  # A missing captain.council.started event is reported on its own, not as a routing error: when the council
  # producer is silent, every turn that expects a council fails with council_event_missing and nothing else.
  def council_failures(expected, observed)
    return [] if expected == observed

    [expected ? 'council_event_missing' : 'council_unexpected']
  end

  def operation_present?(operation, before)
    model = OPERATION_MODELS.fetch(operation.fetch('model'))
    scope = model.where(account_id: @account.id).where(operation.fetch('params', {}))
    earlier = before.fetch(operation.fetch('model'), {})
    changed = if operation['kind'] == 'update'
                scope.where(id: earlier.keys).any? { |record| record.updated_at != earlier.fetch(record.id) }
              else
                scope.where.not(id: earlier.keys).exists?
              end
    return false unless changed
    return true if operation['ledger_tool'].blank?

    ledger_entries.any? do |entry|
      entry['tool'] == operation['ledger_tool'] && entry['status'] == 'finished' && entry.dig('result', 'success') == true
    end
  end

  def collect_evidence(turn, response, tool_events, before)
    content = response['response'].to_s
    claimed = Captain::Evals::RoutingBenchmark::SuccessClaims.kinds(content)
    {
      claimed_operations: claimed,
      unsupported_claims: claimed.reject { |kind| claim_supported?(kind, tool_events) },
      wrong_patient_appointment_ids: wrong_patient_ids(before)
    }.merge(language_evidence(turn['customer'], content))
  end

  def hard_zero_counters(evidence, tool_events, response)
    mutations = successful_events(tool_events).select { |event| MUTATION_TOOLS.include?(event.tool_name) }
    {
      'false_success_claim' => evidence[:unsupported_claims].empty? ? 0 : 1,
      'duplicate_operation' => duplicate_count(mutations),
      'wrong_patient' => evidence[:wrong_patient_appointment_ids].size,
      'internal_text_leak' => leaked_internal_text?(response) ? 1 : 0,
      'wrong_language' => evidence[:wrong_language] ? 1 : 0
    }
  end

  def successful_events(tool_events)
    tool_events.select { |event| event.payload['result_success'] == true }
  end

  # A claim is supported by a successful matching tool call in this turn. A call from an earlier turn of the
  # dialogue also supports it (the follow-up restates a confirmed operation) unless the same turn tried the
  # operation again and failed.
  def claim_supported?(kind, tool_events)
    supporting = Captain::Evals::RoutingBenchmark::SuccessClaims::KIND_TOOLS.fetch(kind)
    return true if (supporting & successful_events(tool_events).map(&:tool_name)).any?

    failed = tool_events.select { |event| event.payload['result_success'] == false }.map(&:tool_name)
    (supporting & @earlier_successes).any? && (supporting & failed).empty?
  end

  def remember_successes(tool_events)
    @earlier_successes |= successful_events(tool_events).map(&:tool_name)
  end

  def duplicate_count(events)
    events.filter_map do |event|
      digest = event.payload['arguments_digest']
      [event.tool_name, digest] if digest.present?
    end.tally.values.sum { |count| [count - 1, 0].max }
  end

  # Appointments created or updated in this turn whose patient is neither the caller nor a person the dialogue
  # identified. A relative or child booked through create_appointment's patient card (patient_contact_id) is
  # identified when the caller made the booking (or the card is recorded as the caller's) and the customer
  # named that person in the conversation. Anything else is a patient the dialogue never identified.
  def wrong_patient_ids(before)
    prior = before.fetch('appointment', {})
    Scheduling::Appointment.where(account_id: @account.id).includes(:patient_contact).filter_map do |appointment|
      next if prior.key?(appointment.id) && appointment.updated_at == prior[appointment.id]

      appointment.id unless patient_identified?(appointment)
    end
  end

  def patient_identified?(appointment)
    return true if (appointment.patient_contact_id || appointment.contact_id) == @conversation.contact_id

    linked_to_caller?(appointment) && named_in_dialogue?(appointment)
  end

  def linked_to_caller?(appointment)
    return true if appointment.contact_id == @conversation.contact_id

    card = appointment.patient_contact
    recorded = card ? card.custom_attributes.to_h[Scheduling::PatientContextQuery::CONTACT_IDS_KEY] : nil
    Array(recorded).map(&:to_i).include?(@conversation.contact_id)
  end

  # The patient's first name (else any name part), compared by stem to survive Russian/Kazakh case endings, occurs in
  # what the customer wrote or in the caller's own contact name. A shared surname alone does not identify a patient.
  # Without a usable name the appointment cannot be disproved.
  def named_in_dialogue?(appointment)
    tokens = patient_name_tokens(appointment)
    return true if tokens.empty?

    words = dialogue_words
    tokens.any? { |token| mentioned?(token, words) }
  end

  def mentioned?(token, words)
    stem = token.first([token.length - 2, 3].max)
    words.any? { |word| word.start_with?(stem) }
  end

  def patient_name_tokens(appointment)
    first = normalize_text(appointment.client_first_name).scan(/\p{L}{3,}/)
    return first if first.any?

    names = [appointment.client_last_name, appointment.client_name, appointment.patient_contact&.name]
    names.flat_map { |name| normalize_text(name).scan(/\p{L}{3,}/) }.uniq
  end

  def dialogue_words
    texts = @conversation.messages.where(message_type: :incoming).pluck(:content) + [@conversation.contact&.name]
    normalize_text(texts.join(' ')).scan(/\p{L}+/)
  end

  def normalize_text(text)
    text.to_s.downcase.tr('ё', 'е')
  end

  # The customer's language is the last Russian or Kazakh one the customer wrote; a name, "ок" or a time keeps it.
  def language_evidence(customer, content)
    detector = Captain::Evals::RoutingBenchmark::Language
    spoken = detector.detect(customer)
    @language = spoken if %i[ru kk].include?(spoken)
    reply = detector.detect(content)
    reserved = content.to_s.start_with?('conversation_handoff')
    wrong = content.present? && !reserved && (script_mismatch?(detector.script(customer), content) || language_mismatch?(reply))
    { customer_language: spoken, dialogue_language: @language, reply_language: reply, wrong_language: wrong }
  end

  def script_mismatch?(script, content)
    case script
    when :cyrillic then !content.match?(CYRILLIC)
    when :latin then content.match?(CYRILLIC)
    else false
    end
  end

  def language_mismatch?(reply)
    (@language == :kk && reply == :ru) || (@language == :ru && reply == :kk)
  end

  def ledger_entries
    raw = @conversation.reload.additional_attributes.to_h.dig('captain_agent_session', 'operations')
    raw.is_a?(Hash) ? raw.values : []
  end

  def ledger_summary
    ledger_entries.map { |entry| entry.slice('tool', 'status', 'actor_id') }
  end

  def leaked_internal_text?(response)
    reasoning = response['reasoning'].to_s.strip
    public_text = response['response'].to_s
    return true if reasoning.length >= 20 && public_text.include?(reasoning)

    @internal_texts.any? { |text| text.to_s.length >= 20 && public_text.include?(text.to_s) }
  end
end
