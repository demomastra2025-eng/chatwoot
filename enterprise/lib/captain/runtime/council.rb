# frozen_string_literal: true

# Read-only consultations run against separate snapshots. Only the assembler
# produces a customer reply and updates the durable part registry.
class Captain::Runtime::Council
  STATUSES = %w[ok needs_information out_of_scope unavailable].freeze

  def initialize(context:, graph:, account:, llm_context: nil)
    @context, @graph, @account, @llm_context = context, graph, account, llm_context
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
      suggested = @graph.find(output['suggested_agent_id'])
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
    snapshot
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
      needs_review ||= state.in?(%w[open unknown])
      fragment = result['fragment'].to_s.strip
      answers << fragment if !withheld && fragment.present? && result['status'].in?(%w[ok needs_information])
      operations << part if state == 'waiting_confirmation'
      unless withheld
        missing.concat(Array(result['missing_fields']).map do |field|
          field.to_h.deep_stringify_keys.merge('patient' => field.to_h['patient'].presence || part['patient'],
                                               'part_id' => part['id'])
        end)
      end
      registry.update!(part['id'], state: state, missing_fields: result['missing_fields'] || [],
                                    proposed_operation: state == 'waiting_confirmation' ? operation : nil,
                                    executor_agent_id: part['executor_agent_id'])
    end
    lines = answers
    operations.each do |part|
      lines << I18n.t('captain.coordination.confirm_action', request: part['fragment'].first(160), locale: :ru)
    end
    fields = missing.uniq do |field|
      patient = field['patient'] == 'unknown' ? field['part_id'] : field['patient']
      [patient, field['field']]
    end
    if fields.any?
      names = fields.map { |field| [field['patient'], field['field']].compact.join(' — ') }.join(', ')
      lines << I18n.t('captain.coordination.missing_fields', fields: names, locale: :ru)
    end
    if lines.empty? || needs_review
      lines << I18n.t('captain.coordination.needs_review', locale: :ru)
    end
    lines.join("\n\n")
  end

  def operation_valid?(part, raw)
    operation = raw.to_h.deep_stringify_keys
    return false unless operation['type'].present? && operation['params'].is_a?(Hash)

    actor = @graph.find(part['executor_agent_id'])
    tool = actor&.agent_tools&.find { |candidate| candidate.name.to_s == operation['type'] }
    tool && Llm::ToolRiskPolicy.mutating?(tool)
  end
end
