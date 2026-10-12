# frozen_string_literal: true

class Captain::Runtime::PartPlanTool < Captain::Runtime::Tool
  EXECUTOR_DESCRIPTION = 'Agent name exactly as listed. Omit it for your own parts. Staff are not an agent: use the handoff tool.'

  description 'Coordinate with other agents: split one message into parts for different agents (a council), or send the patient\'s ' \
              'answer, correction or cancellation of an open part to the agent that owns it. Not for your own work, and not for ' \
              'passing the whole conversation to one colleague: use that colleague\'s transfer tool.'
  param :mode, type: 'string', required: true,
               desc: 'council: parts for different agents, or one linked part of another agent. answer_myself: only your own part. ' \
                     'clarify: one question when it is unclear which open part the message answers.'
  param :parts, type: 'array', required: true,
                desc: 'The parts of the message. A council has at most three; one linked part of another agent is enough.'
  param :clarification, type: 'string', desc: 'The one precise question, for clarify only.', required: false
  param :answer, type: 'string', required: false,
                 desc: 'For one simple part of your own: the final answer, only when it is fully verified from the data you have ' \
                       'and needs no tool.'

  def name = 'plan_request'

  def params_schema
    super.deep_stringify_keys.tap do |schema|
      schema['properties']['parts']['items'] = {
        'type' => 'object', 'additionalProperties' => false,
        'properties' => part_properties.merge(link_properties),
        'required' => %w[fragment]
      }
    end
  end

  # A model that still sends the former numeric executor_agent_id (or a number as the executor) or the former link action
  # 'confirmation' is understood, not rejected. A part number written as a number is read as text.
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
    parts = with_part_ids(parts, context[:parts])
    resolver = Captain::Runtime::ExecutorResolver.new(context)
    resolver.reject_transfer_mode!(mode, parts)
    plan = Captain::Runtime::PartRegistry.new(context).accept!(
      mode: mode, parts: parts, clarification: clarification, answer: answer
    ) { |items| resolver.resolve(items, mode: mode) }
    { mode: plan[:mode], parts: plan[:parts].map { |part| presented(part, resolver) } }.to_json
  rescue Captain::Runtime::ExecutorResolver::RetryableError => e
    rejected(e.message, retryable: true, reason: e.reason)
  rescue ArgumentError, TypeError, KeyError => e
    rejected(e.message, retryable: e.message != Captain::Runtime::PartRegistry::ALREADY_PLANNED)
  end

  private

  def part_properties
    {
      'fragment' => { 'type' => 'string', 'description' => 'The patient\'s words that make this part.' },
      'executor' => { 'type' => %w[string null], 'description' => EXECUTOR_DESCRIPTION },
      'patient' => { 'type' => 'string', 'description' => 'Whom the part is about, when it is not the person writing.' },
      'relation' => { 'type' => 'string', 'enum' => Captain::Runtime::PartRegistry::RELATIONS,
                      'description' => 'independent (default); depends_on: starts only after the part before it succeeded; ' \
                                       'conditional: its owner decides from the result of the part before it.' }
    }
  end

  def link_properties
    {
      'object_refs' => { 'type' => 'array', 'description' => 'Records this part is about, when you know their type and id.',
                         'items' => {
                           'type' => 'object', 'additionalProperties' => false,
                           'properties' => { 'type' => { 'type' => 'string' }, 'id' => { 'type' => 'integer', 'minimum' => 1 } },
                           'required' => %w[type id]
                         } },
      'link_part_id' => { 'type' => %w[string integer null],
                          'description' => 'Number of the open part that this message answers, corrects or cancels, as listed ' \
                                           '(for #3 write 3).' },
      'link_action' => { 'type' => 'string', 'enum' => Captain::Runtime::PartRegistry::LINK_ACTIONS,
                         'description' => 'new: a separate new request, also while other parts are open. answer, correction, ' \
                                          'cancellation: the patient\'s reaction to the linked part.' }
    }
  end
  def rejected(message, retryable:, reason: nil)
    audit = { failure_stage: 'tool_arguments', mutation_executed: false }
    audit[:failure_reason] = reason if reason
    Captain::ToolResult.failure(error: message, retryable: retryable, audit: audit)
  end

  # The model links a part by the number it is listed with (#3); the registry stores the exact id. A reference that points at no
  # stored part is refused here, as the registry refuses a part that is not open, so that the model is told what is wrong with the
  # link and not, for example, that a council needs a second agent.
  def with_part_ids(parts, stored)
    return parts unless parts.is_a?(Array)

    parts.map { |part| part.is_a?(Hash) ? with_part_id(part, stored) : part }
  end

  def with_part_id(part, stored)
    key = part.key?(:link_part_id) ? :link_part_id : 'link_part_id'
    return part if part[key].blank?

    id = Captain::Runtime::PartRegistry.part_id_for(stored, part[key])
    raise ArgumentError, 'Linked part is not open' if Array(stored).none? { |item| item['id'] == id }

    part.merge(key => id)
  end

  # The model reads agents by name only: an accepted part shows its executor's name, never a numeric id.
  def presented(part, resolver)
    { id: part['id'], version: part['version'], executor: resolver.name_for(part['executor_agent_id']) }.compact
  end

  def with_current_names(part)
    renamed = with_text_executor(part)
    renamed[:link_action] = 'answer' if renamed[:link_action].to_s == 'confirmation'
    renamed[:link_part_id] = renamed[:link_part_id].to_s if renamed[:link_part_id].is_a?(Integer)
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
