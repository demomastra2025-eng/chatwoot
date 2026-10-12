# frozen_string_literal: true

class Captain::Runtime::PartPlanTool < Captain::Runtime::Tool
  EXECUTOR_DESCRIPTION = 'Name of the agent that handles this part, exactly as listed. Omit it for your own parts. ' \
                         'Staff or an operator is not an agent: reach them with the handoff tool.'

  description 'Coordinate with other agents: split a message into separate requests for different agents (a council), or route ' \
              'the customer\'s answer, correction or cancellation of an open part of another agent to that agent (a council with ' \
              'that one part linked by its exact ID). The agents carry their parts out with their own tools. ' \
              'Not needed for your own lookups, replies or actions, nor to pass the conversation to one colleague: ' \
              'that colleague\'s transfer tool does it without a plan.'
  param :mode, type: 'string', desc: 'answer_myself, council, or clarify', required: true
  param :parts, type: 'array', required: true,
                desc: 'Request parts with fragment, patient, relation, optional executor (the agent name exactly as listed; omit it ' \
                      'for your own parts) and optional link_part_id; council permits at most three, and one linked part is enough'
  param :clarification, type: 'string', desc: 'One precise question only for clarify mode', required: false
  param :answer, type: 'string', desc: 'For one simple part only: final answer verified from supplied context without tools', required: false

  def name = 'plan_request'

  def params_schema
    super.deep_stringify_keys.tap do |schema|
      schema['properties']['parts']['items'] = {
        'type' => 'object', 'additionalProperties' => false,
        'properties' => {
          'fragment' => { 'type' => 'string' },
          'executor' => { 'type' => %w[string null], 'description' => EXECUTOR_DESCRIPTION },
          'patient' => { 'type' => 'string' },
          'relation' => { 'type' => 'string', 'enum' => Captain::Runtime::PartRegistry::RELATIONS },
          'object_refs' => { 'type' => 'array', 'items' => {
            'type' => 'object', 'additionalProperties' => false,
            'properties' => { 'type' => { 'type' => 'string' }, 'id' => { 'type' => 'integer', 'minimum' => 1 } },
            'required' => %w[type id]
          } },
          'link_part_id' => { 'type' => %w[string null] },
          'link_action' => { 'type' => 'string', 'enum' => Captain::Runtime::PartRegistry::LINK_ACTIONS }
        },
        'required' => %w[fragment]
      }
    end
  end

  # A model that still sends the former numeric executor_agent_id (or a number as the executor) or the former link action
  # 'confirmation' is understood, not rejected.
  def normalize_runtime_arguments(arguments, **_options)
    normalized = arguments.to_h.deep_symbolize_keys
    return normalized unless normalized[:parts].is_a?(Array)

    normalized.merge(parts: normalized[:parts].map { |part| part.is_a?(Hash) ? with_current_names(part) : part })
  end

  # Every rejection of the plan is something the model can correct by calling plan_request again, so it is retryable:
  # a non-retryable failure would turn the identical second call into a terminal stop and end the turn in the generic error.
  # Only a second, different plan for a message that is already planned cannot be corrected.
  def perform(tool_context, mode:, parts:, clarification: nil, answer: nil)
    context = tool_context.run_context.context
    resolver = Captain::Runtime::ExecutorResolver.new(context)
    resolver.reject_transfer_mode!(mode, parts)
    plan =Captain::Runtime::PartRegistry.new(context).accept!(
      mode: mode, parts: parts, clarification: clarification, answer: answer
    ) { |items| resolver.resolve(items, mode: mode) }
    { mode: plan[:mode], parts: plan[:parts].map { |part| presented(part, resolver) } }.to_json
  rescue Captain::Runtime::ExecutorResolver::RetryableError => e
    rejected(e.message, retryable: true, reason: e.reason)
  rescue ArgumentError, TypeError, KeyError => e
    rejected(e.message, retryable: e.message != Captain::Runtime::PartRegistry::ALREADY_PLANNED)
  end

  private

  def rejected(message, retryable:, reason: nil)
    audit = { failure_stage: 'tool_arguments', mutation_executed: false }
    audit[:failure_reason] = reason if reason
    Captain::ToolResult.failure(error: message, retryable: retryable, audit: audit)
  end

  # The model reads agents by name only: an accepted part shows its executor's name, never a numeric id.
  def presented(part, resolver)
    { id: part['id'], version: part['version'], executor: resolver.name_for(part['executor_agent_id']) }.compact
  end

  def with_current_names(part)
    renamed = with_text_executor(part)
    renamed[:link_action] = 'answer' if renamed[:link_action].to_s == 'confirmation'
    renamed
  end

  # The former numeric id is passed on as the agent key (assistant_<id>) so that it stays distinguishable from a guessed number.
  def with_text_executor(part)
    executor = part[:executor].presence || legacy_agent_key(part[:executor_agent_id])
    rest = part.except(:executor, :executor_agent_id)
    executor.nil? ? rest : rest.merge(executor: executor.to_s)
  end

  def legacy_agent_key(value)
    value.to_s.match?(/\A\d+\z/) ? "assistant_#{value}" : value
  end
end
