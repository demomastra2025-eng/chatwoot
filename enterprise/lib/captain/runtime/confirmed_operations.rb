# frozen_string_literal: true

# A confirmation executes the exact recorded proposal, one part at a time.
# The executor uses its normal tool boundary and durable operation receipt.
class Captain::Runtime::ConfirmedOperations
  def initialize(context:, graph:)
    @context, @graph = context, graph
  end

  def run(parts)
    previous_actor = Current.executed_by
    parts.map { |part| execute_part(part) }.join("\n\n")
  ensure
    Current.executed_by = previous_actor
    @context.delete(:active_part_id)
    @context.delete(:active_part_version)
  end

  private

  def execute_part(part)
    return I18n.t('captain.coordination.needs_review', locale: :ru) unless part['relation'].blank? || part['relation'] == 'independent'

    actor = @graph.find(part['executor_agent_id'])
    operation = part['proposed_operation'].to_h.deep_stringify_keys
    tool = actor&.agent_tools&.find { |candidate| candidate.name.to_s == operation['type'].to_s }
    unless tool && Llm::ToolRiskPolicy.mutating?(tool) && operation['params'].is_a?(Hash)
      mark(part, 'failed')
      return I18n.t('captain.coordination.action_unavailable', locale: :ru)
    end

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
    captured = nil
    callback = ->(_name, result, _wrapper) { captured = result }
    wrapper = Captain::Runtime::RunContext.new(@context, callbacks: { tool_complete: [callback] })
    Captain::Runtime::ToolWrapper.new(tool, wrapper).call(operation['params'])
    raise 'Action outcome unavailable' if captured.nil?

    result = Captain::ToolResult.normalize(captured)
    if Captain::ToolResult.error?(result)
      state = result.dig(:audit, :mutation_executed) == false ? 'failed' : 'unknown'
      mark(part, state)
      return I18n.t("captain.coordination.action_#{state == 'failed' ? 'failed' : 'pending'}", locale: :ru)
    end

    if provider_pending?(result)
      mark(part, 'open')
      return I18n.t('captain.coordination.action_pending', locale: :ru)
    end

    mark(part, 'done')
    I18n.t('captain.coordination.action_done', locale: :ru)
  rescue Captain::Conversation::ControlGenerationStaleError
    raise
  rescue StandardError
    mark(part, 'unknown')
    I18n.t('captain.coordination.action_pending', locale: :ru)
  end

  def mark(part, state)
    Captain::Runtime::PartRegistry.new(@context).update!(part['id'], state: state)
  end

  def provider_pending?(result)
    data = result[:data].to_h.with_indifferent_access
    data[:provider_confirmation_required] == true && data[:provider_confirmed] != true
  end
end
