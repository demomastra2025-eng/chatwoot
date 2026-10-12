# frozen_string_literal: true

# Read-only consultations run against separate snapshots. Only the assembler
# produces a customer reply and updates the durable part registry.
class Captain::Runtime::Council
  STATUSES = %w[ok needs_information out_of_scope unavailable].freeze
  ROLE_LABELS = %w[unknown self caller customer patient user собеседник пациент пользователь клиент].freeze
  UNRESOLVED_STATES = %w[open unknown].freeze
  HANDOFF_REASON = 'council_unresolved'
  MAX_FACTS = 8
  MAX_VALUE_LENGTH = 300
  # Keys that name an identifier or a secret, in snake_case (slot_id) and camelCase (slotId).
  IDENTIFIER_KEY = Regexp.union(/(\A|_)(ids?|uuid|token|secret)\z/i, /[a-z](Ids?|Uuid|Token|Secret)\z/)
  UTC_TIMESTAMP = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]00:?00)\z/

  # model: the acting agent's runtime model, used by the composer that writes the single customer reply.
  def initialize(context:, graph:, account:, llm_context: nil, model: nil)
    @context, @graph, @account, @llm_context, @model = context, graph, account, llm_context, model
  end

  def run(parts)
    ids = parts.pluck('id')
    participants = parts.pluck('executor_agent_id').uniq
    Captain::Runtime::CoordinationEvents.council_started(context: @context, participant_ids: participants, part_ids: ids)
    results = parts.map do |part|
      Thread.new do
        Rails.application.executor.wrap { consult(part) }
      rescue Captain::Conversation::ControlGenerationStaleError
        raise
      rescue StandardError
        unavailable
      end
    end.map(&:value)
    participants |= results.flat_map { |result| Array(result['_participants']) }
    reply = assemble(parts, results)
    @context[:council_contributors] = participants.filter_map do |id|
      actor = @graph.find(id)
      { id: actor.id, name: actor.name, avatar_url: actor.avatar_url } if actor
    end
    Captain::Runtime::CoordinationEvents.council_finished(context: @context, participant_ids: participants,
                                                           part_ids: ids, outcome: 'assembled')
    reply
  rescue StandardError
    Captain::Runtime::CoordinationEvents.council_finished(context: @context, participant_ids: participants || [],
                                                           part_ids: ids || [], outcome: 'unavailable')
    raise
  end

  private

  def consult(part, reassigned: false)
    actor = fresh_actor(part.fetch('executor_agent_id'))
    return unavailable unless actor

    Current.executed_by = actor
    runtime = actor.agent
    agent = Captain::Runtime::Agent.new(
      name: runtime.name, instructions: runtime.instructions, tools: runtime.tools,
      model: runtime.model, temperature: runtime.temperature
    )
    agent.assistant_id = actor.id
    snapshot = consult_snapshot(actor, part)
    result = Captain::Runtime::Runner.new.run(
      agent, part.fetch('fragment'), context: snapshot, account: @account,
      llm_context: @llm_context, max_turns: 8
    )
    output = parse_result(result)
    if output['status'] == 'out_of_scope' && !reassigned
      suggested = suggested_agent(output)
      if suggested && suggested.id != actor.id
        reassigned_result = consult(part.merge('executor_agent_id' => suggested.id), reassigned: true)
        return reassigned_result.merge('_participants' => ([actor.id] + Array(reassigned_result['_participants'])).uniq)
      end
    end
    output.merge('_participants' => [actor.id], '_executor_agent_id' => actor.id)
  rescue Captain::Conversation::ControlGenerationStaleError
    raise
  rescue StandardError
    unavailable
  ensure
    Current.executed_by = nil
  end

  # The consultant names the agent as it is listed in its prompt and never sees an id; an unknown or ambiguous name reassigns nothing.
  def suggested_agent(output)
    wanted = Captain::Runtime::ExecutorResolver.normalize(output['suggested_agent'])
    return if wanted.empty?

    matches = @graph.agents.select { |agent| Captain::Runtime::ExecutorResolver.normalize(agent.name) == wanted }
    matches.first if matches.one?
  end

  def fresh_actor(id)
    entry = Captain::Assistant.find_by(id: @graph.entry.id, account_id: @account.id)
    return unless entry

    Captain::AgentGraph.new(entry, inbox: @graph.inbox).find(id)
  end

  def consult_snapshot(actor, part)
    snapshot = @context.deep_dup.except(:agent_session, :agent_graph, :agent_graph_object, :agent_run_context_object,
                                         :agent_tasks, :parts, :part_plan, :pending_handoff,
                                         :captain_v2_completed_tool_results)
    snapshot[:consult_mode] = true
    snapshot[:conversation_history] = public_history(@context[:conversation_history])
    snapshot[:current_agent] = actor.agent_name
    state = snapshot[:state] ||= {}
    state[:assistant_id] = actor.id
    state[:assistant_config] = actor.config
    state[:captain_runtime] = Captain::AssistantSafetyPreferences.for(assistant: actor, feature: :assistant)
    state[:prompt_context] = actor.prompt_context_state(state)
    state[:captain_response_fence] = state[:captain_response_fence].to_h.with_indifferent_access.except(:routing_revision)
    snapshot[:consult_part] = part.slice('id', 'version', 'patient', 'relation')
    snapshot[:consult_peers] = consult_peers(actor)
    snapshot
  end

  # The other agents of the channel by name and responsibility, so a consultant can say who handles a part that is not its own.
  def consult_peers(actor)
    Array(@context[:agent_graph]).reject { |item| item[:id] == actor.id }.map { |item| item.slice(:name, :description) }
  end

  def public_history(history)
    Array(history).filter_map do |raw|
      message = raw.to_h.with_indifferent_access
      next unless %w[user assistant].include?(message[:role].to_s)
      next if message[:tool_calls].present?

      content = message[:content]
      if message[:role].to_s == 'assistant'
        parsed = content.is_a?(String) ? JSON.parse(content) : content
        content = parsed['response'].to_s if parsed.is_a?(Hash) && parsed.key?('response')
      end
      { role: message[:role], content: content }
    rescue JSON::ParserError
      nil
    end
  end

  def parse_result(result)
    return unavailable if result.error

    raw = result.output
    parsed = raw.is_a?(Hash) ? raw.deep_stringify_keys : JSON.parse(raw.to_s)
    parsed = JSON.parse(parsed['response']) if parsed['status'].blank? && parsed['response'].is_a?(String)
    return unavailable unless STATUSES.include?(parsed['status'])

    parsed['facts'] = Array(parsed['facts']).select { |fact| fact.is_a?(Hash) && fact['source'].present? }
    parsed['missing_fields'] = Array(parsed['missing_fields']).select do |field|
      field.is_a?(Hash) && field['field'].present? && field['purpose'].present?
    end
    parsed['contradictions'] = Array(parsed['contradictions']).reject(&:blank?)
    parsed['proposed_operation'] = nil unless parsed['proposed_operation'].is_a?(Hash)
    parsed['status'] = 'unavailable' if parsed['status'] == 'ok' && parsed['facts'].empty? && parsed['fragment'].present?
    parsed
  rescue JSON::ParserError
    unavailable
  end

  def unavailable
    { 'status' => 'unavailable', 'fragment' => '', 'facts' => [], 'missing_fields' => [],
      'proposed_operation' => nil, 'contradictions' => [] }
  end

  def assemble(parts, results)
    registry = Captain::Runtime::PartRegistry.new(@context)
    answers = []
    operations = []
    missing = []
    reports = {}
    unresolved = []
    needs_review = false
    parts.zip(results).each do |part, result|
      part['executor_agent_id'] = result['_executor_agent_id'] if result['_executor_agent_id'].present?
      contradictions = Array(result['contradictions']).reject(&:blank?)
      # Independent parts and dependent parts with a resolved prerequisite may be confirmed; the
      # executor runs a dependent part only after its prerequisite is done. Conditional parts stay withheld.
      runnable = Captain::Runtime::PartRegistry.executable_relation?(part)
      operation = result['proposed_operation'] if runnable && operation_valid?(part, result['proposed_operation'])
      invalid_operation = result['proposed_operation'].present? && operation.nil?
      withheld = contradictions.any? || invalid_operation
      state = if withheld || result['status'] == 'out_of_scope'
                'open'
              elsif Array(result['missing_fields']).any?
                'waiting_customer'
              elsif result['status'] == 'ok' && operation.present?
                'waiting_confirmation'
              elsif result['status'] == 'ok'
                'answered'
              else
                'unknown'
              end
      needs_review ||= state.in?(UNRESOLVED_STATES)
      fragment = result['fragment'].to_s.strip
      usable = !withheld && result['status'].in?(%w[ok needs_information])
      # A consultant's clarifying question for the customer is a reply to send, not a part that staff has to answer.
      unresolved_part = state.in?(UNRESOLVED_STATES) && !(usable && result['status'] == 'needs_information' && fragment.present?)
      answers << fragment if usable && fragment.present?
      operations << part if state == 'waiting_confirmation'
      unresolved << part['fragment'].to_s.strip.first(160) if unresolved_part
      unless withheld
        missing.concat(Array(result['missing_fields']).map do |field|
          field.to_h.deep_stringify_keys.merge('patient' => field.to_h['patient'].presence || part['patient'],
                                               'part_id' => part['id'])
        end)
      end
      registry.update!(part['id'], state: state, missing_fields: result['missing_fields'] || [],
                                    proposed_operation: state == 'waiting_confirmation' ? operation : nil,
                                    executor_agent_id: part['executor_agent_id'])
      reports[part['id']] = part_report(part, result, state: state, usable: usable, operation: operation, unresolved: unresolved_part)
    end
    fields = missing.uniq do |field|
      patient = field['patient'] == 'unknown' ? field['part_id'] : field['patient']
      [patient, field['field']]
    end
    template = template_reply(answers, operations, fields, needs_review)
    composed_reply(parts, reports, fields, unresolved, pending_confirmation: operations.any?) || template
  end

  # The fixed-template reply: the fallback whenever the composer does not produce a valid reply.
  def template_reply(answers, operations, fields, needs_review)
    lines = answers.dup
    operations.each do |part|
      lines << I18n.t('captain.coordination.confirm_action', request: part['fragment'].first(160), locale: reply_language.to_sym)
    end
    lines.concat(missing_field_lines(fields)) if fields.any?
    lines << I18n.t('captain.coordination.needs_review', locale: reply_language.to_sym) if lines.empty? || needs_review
    lines.join("\n\n")
  end

  # One model call writes the single customer reply from the results of the consultations. Any failure keeps the
  # template reply and publishes why. A part left unresolved is promised to staff only when a real handoff will follow:
  # the response builder performs it after the reply is delivered (see context[:council_handoff]). While a part waits for
  # the customer's yes or no there is no handoff: staff would answer that yes, and the stored proposal must stay with the
  # agent that can run it. The unresolved part then stays open and nothing is promised for it.
  def composed_reply(parts, reports, fields, unresolved, pending_confirmation: false)
    @context.delete(:council_handoff)
    ids = parts.pluck('id')
    handoff = unresolved.any? && !pending_confirmation && staff_handoff_available?
    outcome = Captain::Runtime::CouncilComposer.new(
      context: @context, graph: @graph, account: @account, llm_context: @llm_context, model: composer_model
    ).compose(message: customer_message, language: reply_language, parts: attach_questions(reports, fields), staff_handoff: handoff)
    if outcome.reply.blank?
      Captain::Runtime::CoordinationEvents.council_composer_fallback(context: @context, part_ids: ids, reason: outcome.reason)
      return
    end

    @context[:council_handoff] = { reason: HANDOFF_REASON, parts: unresolved } if handoff
    Captain::Runtime::CoordinationEvents.council_composed(context: @context, part_ids: ids, language: reply_language, handoff: handoff)
    outcome.reply
  rescue Captain::Conversation::ControlGenerationStaleError
    raise
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][Council] composer unavailable error_class=#{e.class.name}")
    Captain::Runtime::CoordinationEvents.council_composer_fallback(context: @context, part_ids: ids || [], reason: 'error')
    nil
  end

  # What the composer may know about one part: customer-facing data only, never identifiers or role labels.
  def part_report(part, result, state:, usable:, operation:, unresolved:)
    {
      'request' => part['fragment'].to_s.strip.first(300),
      'patient' => patient_name(part['patient']),
      'answer' => (result['fragment'].to_s.strip.presence if usable),
      'facts' => (compact_facts(result['facts']) if usable),
      'confirm' => (confirmation(part, operation) if state == 'waiting_confirmation'),
      'unresolved' => (true if unresolved)
    }.compact_blank
  end

  # Each missing item is asked once: the fields are already de-duplicated per patient across all parts.
  def attach_questions(reports, fields)
    fields.group_by { |field| field['part_id'] }.each do |part_id, items|
      next unless reports[part_id]

      reports[part_id]['questions'] = items.filter_map do |field|
        question = field['field'].to_s.strip
        { 'patient' => patient_name(field['patient']), 'question' => question }.compact_blank if question.present?
      end
    end
    reports.values
  end

  def patient_name(value)
    name = value.to_s.strip
    name if name.present? && !ROLE_LABELS.include?(name.downcase)
  end

  def compact_facts(facts)
    Array(facts).first(MAX_FACTS).filter_map { |fact| compact_value(fact, hide_identifiers: true) if fact.is_a?(Hash) }
  end

  # The action is named in the customer's language ("запись на приём"), never by the tool's title. A tool without a label
  # is described by the request and the details alone. The marker keeps a bare confirmation visible to the composer.
  def confirmation(part, operation)
    details = operation.to_h.deep_stringify_keys
    described = { 'action' => action_label(details['type'].to_s), 'patient' => patient_name(part['patient']),
                  'details' => compact_value(details['params'], hide_identifiers: true) }.compact_blank
    described.presence || { 'yes_no' => true }
  end

  def action_label(type)
    key = "captain.coordination.action.#{type}"
    I18n.t(key, locale: reply_language.to_sym) if type.match?(/\A[a-z][a-z_]*\z/) && I18n.exists?(key, reply_language.to_sym)
  end

  def compact_value(value, depth = 0, hide_identifiers: false)
    case value
    when Hash
      return if depth > 2

      value.each_with_object({}) do |(key, item), clean|
        next if hide_identifiers && key.to_s.match?(IDENTIFIER_KEY)

        cleaned = compact_value(item, depth + 1, hide_identifiers: hide_identifiers)
        clean[key.to_s] = cleaned unless cleaned.nil? || cleaned == ''
      end
    when Array then value.first(MAX_FACTS).filter_map { |item| compact_value(item, depth + 1, hide_identifiers: hide_identifiers) }
    when String then local_clock(value.strip.first(MAX_VALUE_LENGTH))
    when Numeric, true, false then value
    end
  end

  # A UTC timestamp is shown as the clinic's local clock, so that the composer never has to convert a time.
  def local_clock(text)
    return text unless text.match?(UTC_TIMESTAMP)

    name = @account&.reporting_timezone.presence
    zone = ActiveSupport::TimeZone[name] if name
    zone ? Time.zone.parse(text).in_time_zone(zone).strftime('%Y-%m-%dT%H:%M') : text
  rescue ArgumentError
    text
  end

  def customer_message
    @customer_message ||= Captain::Runtime::CouncilComposer.customer_text(@context[:captain_v2_current_input]).strip
  end

  def reply_language
    @reply_language ||= Captain::Runtime::CouncilComposer.language_for(customer_message, history: @context[:conversation_history])
  end

  def acting_actor
    @graph&.find(@context[:acting_assistant_id] || @context.dig(:state, :assistant_id)) || @graph&.entry
  end

  def composer_model
    @model.presence || acting_actor&.resolved_agent_model
  end

  # The same conditions the response builder checks before it hands the conversation to staff.
  def staff_handoff_available?
    actor = acting_actor
    @context.dig(:state, :conversation, :id).present? && actor.present? && actor.handoff_enabled? &&
      Array(actor.selected_agent_tool_ids).include?('handoff')
  rescue StandardError
    false
  end

  # Consultants phrase each missing field as a question to the customer; such questions are sent as they are.
  # A patient name is shown only when the questions concern several people; role labels never reach the customer.
  def missing_field_lines(fields)
    named = fields.map do |field|
      patient = field['patient'].to_s.strip
      [ROLE_LABELS.include?(patient.downcase) ? '' : patient, field['field'].to_s.strip]
    end
    named = named.reject { |_patient, question| question.blank? }.uniq
    several = named.map(&:first).reject(&:blank?).uniq.size > 1
    texts = named.map { |patient, question| several && patient.present? ? "#{patient} — #{question}" : question }
    return [texts.join(' ')] if named.all? { |_patient, question| question.end_with?('?') }

    [I18n.t('captain.coordination.missing_fields', fields: texts.join(', '), locale: reply_language.to_sym)]
  end

  def operation_valid?(part, raw)
    operation = raw.to_h.deep_stringify_keys
    return false unless operation['type'].present? && operation['params'].is_a?(Hash)

    actor = @graph.find(part['executor_agent_id'])
    tool = actor&.agent_tools&.find { |candidate| candidate.name.to_s == operation['type'] }
    tool && Llm::ToolRiskPolicy.mutating?(tool)
  end
end
