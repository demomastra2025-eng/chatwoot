# frozen_string_literal: true

# A confirmation executes the exact recorded proposal, one part at a time.
# The executor uses its normal tool boundary and durable operation receipt.
# A dependent part runs only after the part it depends on is done. Otherwise it is left
# open and reported as not started, so a failed, unknown or pending step stops its chain.
class Captain::Runtime::ConfirmedOperations
  REGISTRY_STATES = { 'done' => 'done', 'failed' => 'failed', 'unknown' => 'unknown', 'pending' => 'open' }.freeze

  def initialize(context:, graph:)
    @context, @graph = context, graph
  end

  def run(parts)
    previous_actor = Current.executed_by
    prerequisites_first(parts).map { |part| customer_line(part, labelled: parts.size > 1) }.join("\n\n")
  ensure
    Current.executed_by = previous_actor
    @context.delete(:active_part_id)
    @context.delete(:active_part_version)
  end

  private

  # Several parts are reported one by one, so each outcome names the request it belongs to.
  def customer_line(part, labelled:)
    text = execute_part(part)
    return text unless labelled && part['fragment'].present?

    I18n.t('captain.coordination.part_result', request: part['fragment'].to_s.first(160), result: text, locale: :ru)
  end

  # Keeps the confirmed order, but never places a part before the part it depends on.
  def prerequisites_first(parts)
    by_id = parts.index_by { |part| part['id'] }
    parts.each_with_object([]) { |part, ordered| enqueue(part, by_id, ordered, []) }
  end

  def enqueue(part, by_id, ordered, trail)
    return if ordered.include?(part) || trail.include?(part['id'])

    prerequisite = by_id[part['depends_on_part_id']] if part['relation'] == 'depends_on'
    enqueue(prerequisite, by_id, ordered, trail + [part['id']]) if prerequisite
    ordered << part
  end

  def execute_part(part)
    return settle(part, 'not_started', 'needs_review') unless Captain::Runtime::PartRegistry.executable_relation?(part)
    return settle(part, 'not_started', 'action_not_started') unless prerequisite_done?(part)

    actor = @graph.find(part['executor_agent_id'])
    operation = part['proposed_operation'].to_h.deep_stringify_keys
    tool = actor&.agent_tools&.find { |candidate| candidate.name.to_s == operation['type'].to_s }
    return settle(part, 'failed', 'action_unavailable') unless tool && Llm::ToolRiskPolicy.mutating?(tool) && operation['params'].is_a?(Hash)

    run_tool(part, actor, tool, operation['params'])
  rescue Captain::Conversation::ControlGenerationStaleError
    raise
  rescue StandardError
    settle(part, 'unknown', 'action_pending')
  end

  def prerequisite_done?(part)
    return true unless part['relation'] == 'depends_on'

    prerequisite = Array(@context[:parts]).find { |item| item['id'] == part['depends_on_part_id'] }
    prerequisite.present? && prerequisite['state'] == 'done' && prerequisite['cancelled'] != true
  end

  def run_tool(part, actor, tool, params)
    bind(part, actor, tool)
    Captain::Runtime::CoordinationEvents.operation_started(context: @context, part: part, tool_name: tool.name.to_s)
    captured = call_tool(tool, params)
    raise 'Action outcome unavailable' if captured.nil?

    settle(part, *outcome_for(Captain::ToolResult.normalize(captured)))
  end

  def bind(part, actor, tool)
    @context[:agent_run_context_object].activate(actor, @context)
    @context[:active_part_id] = part['id']
    @context[:active_part_version] = part['version']
    fence = @context.dig(:state, :captain_response_fence)
    fence[:part_id] = part['id'] if fence
    fence[:part_version] = part['version'] if fence
    @context[:captain_v2_bound_tool_ids_by_agent] ||= {}
    @context[:captain_v2_bound_tool_ids_by_agent][actor.agent_name] = [tool.name.to_s]
    @context[:captain_v2_bound_tool_ids] = [tool.name.to_s]
    batch_id = SecureRandom.uuid
    @context[:captain_v2_current_tool_batch_id] = batch_id
    @context[:captain_v2_mutating_tool_calls_by_batch] ||= {}
    @context[:captain_v2_mutating_tool_calls_by_batch][batch_id] = []
  end

  def call_tool(tool, params)
    captured = nil
    callback = ->(_name, result, _wrapper) { captured = result }
    wrapper = Captain::Runtime::RunContext.new(@context, callbacks: { tool_complete: [callback] })
    Captain::Runtime::ToolWrapper.new(tool, wrapper).call(params)
    captured
  end

  # Returns the outcome state and the matching customer text. Anything that is not a verified
  # success or a verified non-execution stays unknown or pending and never reads as success.
  def outcome_for(result)
    if Captain::ToolResult.error?(result)
      result.dig(:audit, :mutation_executed) == false ? %w[failed action_failed] : %w[unknown action_pending]
    elsif provider_pending?(result)
      %w[pending action_pending]
    else
      %w[done action_done]
    end
  end

  # Records the part state, publishes the outcome (ids only) and returns the customer text.
  def settle(part, state, text_key)
    mark(part, REGISTRY_STATES[state]) if REGISTRY_STATES.key?(state)
    Captain::Runtime::CoordinationEvents.operation_finished(context: @context, part: part, tool_name: operation_type(part), state: state)
    I18n.t("captain.coordination.#{text_key}", locale: :ru)
  end

  # The provider call already happened: its outcome is stored even if the run is no longer current.
  def mark(part, state)
    Captain::Runtime::PartRegistry.new(@context).record_outcome!(part['id'], state)
  end

  def operation_type(part)
    part['proposed_operation'].to_h['type'].to_s.presence
  rescue StandardError
    nil
  end

  def provider_pending?(result)
    data = result[:data].to_h.with_indifferent_access
    data[:provider_confirmation_required] == true && data[:provider_confirmed] != true
  end
end
