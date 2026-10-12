# frozen_string_literal: true

# Read-only consultations run against separate snapshots. Each consultant writes the final text of its part; only the
# assembler produces the customer reply (the composer rewrites the part texts into one message) and updates the durable
# part registry.
class Captain::Runtime::Council
  STATUSES = %w[ok needs_information out_of_scope unavailable].freeze
  UNRESOLVED_STATES = %w[open unknown].freeze
  HANDOFF_REASON = 'council_unresolved'
  PART_SEPARATOR = "\n\n"

  # model: the acting agent's runtime model, used by the composer that writes the single customer reply.
  def initialize(context:, graph:, account:, llm_context: nil, model: nil)
    @context, @graph, @account, @llm_context, @model = context, graph, account, llm_context, model
  end

  def run(parts)
    ids = parts.pluck('id')
    participants = parts.pluck('executor_agent_id').uniq
    Captain::Runtime::CoordinationEvents.council_started(context: @context, participant_ids: participants, part_ids: ids)
    # What the consultants are told is read once, before the threads start.
    reply_language
    staff_handoff_available?
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
    snapshot[:consult_language] = reply_language
    snapshot[:consult_staff_handoff] = staff_handoff_available?
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
    parsed['customer_text'] = parsed['customer_text'].is_a?(String) ? parsed['customer_text'].strip : ''
    # An answer without a verified fact is not an answer: its text is not passed on.
    if parsed['status'] == 'ok' && parsed['facts'].empty? && parsed['customer_text'].present?
      parsed['status'] = 'unavailable'
      parsed['customer_text'] = ''
    end
    parsed
  rescue JSON::ParserError
    unavailable
  end

  def unavailable
    { 'status' => 'unavailable', 'customer_text' => '', 'facts' => [], 'missing_fields' => [],
      'proposed_operation' => nil, 'contradictions' => [] }
  end

  def assemble(parts, results)
    registry = Captain::Runtime::PartRegistry.new(@context)
    entries = parts.zip(results).map { |part, result| settle_part(registry, part, result) }
    composed_reply(parts, entries)
  end

  # Records the state of one part and returns what the reply needs of it: the text of the part, whether it waits for the
  # customer's yes or no, and whether it stays unresolved.
  def settle_part(registry, part, result)
    part['executor_agent_id'] = result['_executor_agent_id'] if result['_executor_agent_id'].present?
    contradictions = Array(result['contradictions']).reject(&:blank?)
    # Independent parts and dependent parts with a resolved prerequisite may be confirmed; the
    # executor runs a dependent part only after its prerequisite is done. Conditional parts stay withheld.
    runnable = Captain::Runtime::PartRegistry.executable_relation?(part)
    operation = result['proposed_operation'] if runnable && operation_valid?(part, result['proposed_operation'])
    invalid_operation = result['proposed_operation'].present? && operation.nil?
    withheld = contradictions.any? || invalid_operation
    # The text of a withheld part is an unverified answer: it is never passed on.
    text = withheld ? '' : result['customer_text'].to_s.strip
    state = part_state(result, text: text, operation: operation, withheld: withheld)
    # A consultant's question for the customer is a reply to send, not a part that staff has to answer.
    unresolved = state.in?(UNRESOLVED_STATES) && !(result['status'] == 'needs_information' && text.present?)
    registry.update!(part['id'], state: state, missing_fields: result['missing_fields'] || [],
                                  proposed_operation: state == 'waiting_confirmation' ? operation : nil,
                                  executor_agent_id: part['executor_agent_id'])
    { text: part_text(state, text, result), confirmation: state == 'waiting_confirmation', unresolved: unresolved,
      request: part['fragment'].to_s.strip.first(160), patient: part['patient'].to_s.strip.downcase }
  end

  # An answer or a confirmation question needs the text that tells the customer so: without it the part is unknown.
  def part_state(result, text:, operation:, withheld:)
    if withheld || result['status'] == 'out_of_scope'
      'open'
    elsif Array(result['missing_fields']).any?
      'waiting_customer'
    elsif result['status'] == 'ok' && text.present?
      operation.present? ? 'waiting_confirmation' : 'answered'
    else
      'unknown'
    end
  end

  # A consultant phrases each missing field as a question to the customer; they stand in for a missing text.
  def part_text(state, text, result)
    return text unless state == 'waiting_customer'

    text.presence || Array(result['missing_fields']).filter_map { |field| field['field'].to_s.strip.presence }.join(' ')
  end

  # The composer rewrites the part texts into one message. Without its reply the texts go out one after another, in the
  # order of the requests. A part left unresolved is promised to staff only when a real handoff will follow: the response
  # builder performs it after the reply is delivered (see context[:council_handoff]). While a part waits for the customer's
  # yes or no there is no handoff: staff would answer that yes, and the stored proposal must stay with the agent that can
  # run it. The unresolved part then stays open and nothing is promised for it.
  def composed_reply(parts, entries)
    @context.delete(:council_handoff)
    unresolved = entries.select { |entry| entry[:unresolved] }
    handoff = unresolved.any? && entries.none? { |entry| entry[:confirmation] } && staff_handoff_available?
    lines = entries.map { |entry| part_line(entry, handoff: handoff) }
    reply = compose_reply(parts.pluck('id'), lines, handoff: handoff) || plain_reply(entries, lines, handoff: handoff)
    @context[:council_handoff] = { reason: HANDOFF_REASON, parts: unresolved.pluck(:request) } if handoff
    reply
  end

  # The consultants were told whether staff can take an unresolved part over, so their sentence is true unless a pending
  # confirmation withdrew the handoff. A part without any text gets one short line that says the same.
  def part_line(entry, handoff:)
    text = stock_line?(entry, handoff: handoff) ? stock_text(handoff) : entry[:text]
    { 'text' => text, 'needs_confirmation' => entry[:confirmation], 'staff_will_answer' => entry[:unresolved] && handoff }
  end

  def stock_line?(entry, handoff:)
    entry[:unresolved] && (entry[:text].blank? || (staff_handoff_available? && !handoff))
  end

  def stock_text(handoff)
    I18n.t("captain.coordination.#{handoff ? 'part_staff_will_answer' : 'part_cannot_answer'}", locale: reply_language.to_sym)
  end

  # Without the composer's reply the part texts go out in the order of the requests. Exact repeats are dropped (the same stock
  # line for two parts, the same question twice for one person); the same words about different people stay, since they ask
  # about different people.
  def plain_reply(entries, lines, handoff:)
    keyed = entries.zip(lines).map do |entry, line|
      [[stock_line?(entry, handoff: handoff) ? nil : entry[:patient], line['text']], line['text']]
    end
    keyed.uniq(&:first).filter_map { |_, text| text.presence }.join(PART_SEPARATOR)
  end

  def compose_reply(ids, lines, handoff:)
    outcome = Captain::Runtime::CouncilComposer.new(
      context: @context, account: @account, llm_context: @llm_context, model: composer_model
    ).compose(message: customer_message, language: reply_language, parts: lines)
    if outcome.reply.blank?
      Captain::Runtime::CoordinationEvents.council_composer_fallback(context: @context, part_ids: ids, reason: outcome.reason)
      return
    end

    Captain::Runtime::CoordinationEvents.council_composed(context: @context, part_ids: ids, language: reply_language, handoff: handoff)
    outcome.reply
  rescue Captain::Conversation::ControlGenerationStaleError
    raise
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][Council] composer unavailable error_class=#{e.class.name}")
    Captain::Runtime::CoordinationEvents.council_composer_fallback(context: @context, part_ids: ids, reason: 'error')
    nil
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
    return @staff_handoff_available if defined?(@staff_handoff_available)

    @staff_handoff_available = begin
      actor = acting_actor
      (@context.dig(:state, :conversation, :id).present? && actor.present? && actor.handoff_enabled? &&
        Array(actor.selected_agent_tool_ids).include?('handoff')).present?
    rescue StandardError
      false
    end
  end

  def operation_valid?(part, raw)
    operation = raw.to_h.deep_stringify_keys
    return false unless operation['type'].present? && operation['params'].is_a?(Hash)

    actor = @graph.find(part['executor_agent_id'])
    tool = actor&.agent_tools&.find { |candidate| candidate.name.to_s == operation['type'] }
    tool && Llm::ToolRiskPolicy.mutating?(tool)
  end
end
