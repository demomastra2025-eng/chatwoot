# frozen_string_literal: true

class Captain::Evals::RoutingBenchmark::Scorer
  OPERATION_MODELS = {
    'appointment' => Scheduling::Appointment,
    'deal' => Crm::Deal,
    'contact' => Contact
  }.freeze
  SUCCESS_CLAIM = /(записал[аи]?|перен[её]с|создал[аи]?|booked|rescheduled|created)/i
  MUTATION_TOOLS = %w[create_appointment update_appointment cancel_appointment create_deal update_deal transition_deal_stage].freeze
  CYRILLIC = /[А-Яа-яЁё]/

  def initialize(account:, conversation:, internal_texts: [])
    @account, @conversation = account, conversation
    @internal_texts = internal_texts
  end

  def call(turn:, response:, events:, before:)
    expected = turn.fetch('expect')
    tool_events = events.select { |event| event.event_name == 'llm.tool.complete' }
    tools = tool_events.map(&:tool_name)
    acting_id = response['agent_id']
    acting_agent = Captain::Assistant.where(account_id: @account.id, id: acting_id).pick(:name)
    accepted = Array(expected['agents'] || expected['agent'])
    council = events.any? { |event| event.event_name == 'captain.council.started' }
    failures = []
    failures << 'runtime_error' if response['captain_request_id'].blank? ||
                                   response['response'].to_s == Captain::Assistant::AgentRunnerService::PROVIDER_ERROR_RESPONSE
    failures << 'wrong_agent' unless accepted.include?(acting_agent)
    failures << 'council_mismatch' unless council == expected['council']
    Array(expected['must_call']).each { |name| failures << "missing_tool:#{name}" unless tools.include?(name) }
    Array(expected['must_not_call']).each { |name| failures << "forbidden_tool:#{name}" if tools.include?(name) }
    Array(expected['operations']).each do |operation|
      failures << "missing_operation:#{operation['model']}" unless operation_present?(operation, before)
    end
    counters = forbidden_counters(turn, response, tool_events, before)
    counters.each { |name, count| failures << name if count.positive? }
    { status: failures.empty? ? 'pass' : 'fail', reasons: failures, acting_agent: acting_agent,
      council: council, tools: tools, hard_zero: counters, operations_ledger: ledger_summary }
  end

  private

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

  def forbidden_counters(turn, response, tool_events, before)
    content = response['response'].to_s
    successful_tools = tool_events.select { |event| event.payload['result_success'] == true && MUTATION_TOOLS.include?(event.tool_name) }
    {
      'false_success_claim' => successful_tools.empty? && content.match?(SUCCESS_CLAIM) ? 1 : 0,
      'duplicate_operation' => duplicate_count(successful_tools),
      'wrong_patient' => wrong_patient_count(before),
      'internal_text_leak' => leaked_internal_text?(response) ? 1 : 0,
      'wrong_language' => turn_language_wrong?(turn['customer'], content) ? 1 : 0
    }
  end

  def duplicate_count(events)
    events.filter_map do |event|
      digest = event.payload['arguments_digest']
      [event.tool_name, digest] if digest.present?
    end.tally.values.sum { |count| [count - 1, 0].max }
  end

  def wrong_patient_count(before)
    prior = before.fetch('appointment', {})
    Scheduling::Appointment.where(account_id: @account.id)
                           .where.not(patient_contact_id: @conversation.contact_id)
                           .count { |appointment| !prior.key?(appointment.id) || appointment.updated_at != prior[appointment.id] }
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

  def turn_language_wrong?(customer, content)
    return false if content.blank?

    customer.to_s.match?(CYRILLIC) ? !content.match?(CYRILLIC) : content.match?(CYRILLIC)
  end
end
