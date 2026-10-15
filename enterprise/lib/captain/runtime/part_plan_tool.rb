# frozen_string_literal: true

class Captain::Runtime::PartPlanTool < Captain::Runtime::Tool
  def initialize(context = nil)
    @planning_context = context
    super()
  end
  EXECUTOR_DESCRIPTION = 'The agent that does this action, by its name exactly as listed under Colleagues. Omit it for your own ' \
                         'action. Staff are not an agent: use the handoff tool.'
  FRAGMENT_DESCRIPTION = 'The patient\'s own words that make this one action.'
  PATIENT_DESCRIPTION = 'Whom the action is about, when it is not the person writing.'
  OBJECT_REFS_DESCRIPTION = 'Records this action is about, when you know their type and id.'
  RELATION_DESCRIPTION = 'How this part follows the part before it in this plan. independent (default). depends_on: the action is ' \
                         'carried out only when the part before it succeeded. conditional ("if X then Y"): its owner decides from ' \
                         'the result of the part before it; list the part that decides first and the conditional part after it. ' \
                         'The patient\'s reaction to an open part goes into link_action.'
  LINK_PART_DESCRIPTION = 'Only when the message answers, corrects or cancels that colleague\'s open part (not when it only confirms ' \
                          'an action already listed under Done in this conversation): its number from the list of open parts (for #3 write 3). ' \
                          'Leave it out for a new action.'
  LINK_ACTION_DESCRIPTION = 'new: a separate new action, also while other parts are open. answer, correction, cancellation: ' \
                            'the patient\'s reaction to the linked open part.'
  MODE_DESCRIPTION = 'council: actions for different agents, or one open part of another agent that the message answers, corrects or ' \
                     'cancels. clarify: one question for the patient, when two or more open parts could be meant and the message ' \
                     'names none.'
  PARTS_DESCRIPTION = 'One item per action, in the order of the patient\'s message; a council has at most three. A single item is ' \
                      'for one open part of another agent that the message answers, corrects or cancels.'
  # The cancellation of parts that never acted runs no agent: the model that planned it answers (see Runner#handle_plan).
  CANCELLED_NOTE = 'The cancellation is recorded and nothing else is to be done. Reply to the patient now: confirm it in one short sentence.'
  AUDIT_TOOL = { id: 'plan_request', title: 'Plan request', risk_level: 'low' }.freeze
  # The audit log hides every key that contains "link" (it may hold a URL), so the link of a part is written under these keys.
  AUDIT_KEYS = { 'link_part_id' => 'open_part', 'link_action' => 'reaction' }.freeze

  description 'Coordinate actions with other agents. Call it once when the patient\'s message holds actions for two or more different ' \
              'agents: it splits the message into parts (a council) and each agent does its part right away. Call it also to send ' \
              'the patient\'s answer, correction or cancellation of an open part to the agent that owns it. When all actions of the ' \
              'message belong to one colleague, transfer the conversation with that colleague\'s transfer tool.'
  param :mode, type: 'string', required: true, desc: MODE_DESCRIPTION
  param :parts, type: 'array', required: true, desc: PARTS_DESCRIPTION
  param :clarification, type: 'string', desc: 'The one precise question, for clarify only.', required: false

  def name = 'plan_request'

  # mode is an enum of the valid modes, so the model is offered nothing else (a former mode such as handoff or answer is not one).
  def params_schema
    super.deep_stringify_keys.tap do |schema|
      schema['properties']['mode']['enum'] = Captain::Runtime::PartRegistry::MODES
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
  # The call is written to the audit log with its arguments (an account with audit_logs), so that a report can show what was planned.
  # A model that still sends the former `answer` is understood: the parameter is dropped, the agent replies itself.
  def perform(tool_context, mode:, parts:, clarification: nil, **_former)
    result = accept_plan(tool_context.run_context.context, mode, parts, clarification)
    audit(tool_context, { mode: mode, parts: audit_parts(parts), clarification: clarification }.compact, result)
    result
  end

  private

  def accept_plan(context, mode, parts, clarification)
    parts = with_part_ids(parts, context)
    resolver = Captain::Runtime::ExecutorResolver.new(context)
    resolver.reject_transfer_mode!(mode, parts)
    plan = Captain::Runtime::PartRegistry.new(context).accept!(
      mode: mode, parts: parts, clarification: clarification
    ) { |items| resolver.resolve(items, mode: mode) }
    result = { mode: plan[:mode], parts: plan[:parts].map { |part| presented(part, resolver) } }
    result[:note] = CANCELLED_NOTE if plan[:parts].all? { |part| part['link_action'] == 'cancellation' }
    result.to_json
  rescue Captain::Runtime::ExecutorResolver::RetryableError => e
    rejected(e.message, retryable: true, reason: e.reason)
  rescue ArgumentError, TypeError, KeyError => e
    rejected(e.message, retryable: e.message != Captain::Runtime::PartRegistry::ALREADY_PLANNED)
  end

  def part_properties
    names = Array(@planning_context&.dig(:agent_graph)).reject do |agent|
      agent[:id] == @planning_context.dig(:state, :assistant_id)
    end.pluck(:name)
    {
      'fragment' => { 'type' => 'string', 'description' => FRAGMENT_DESCRIPTION },
      'executor' => { 'type' => %w[string null], 'description' => EXECUTOR_DESCRIPTION }.tap do |schema|
        schema['enum'] = [nil, *names] if @planning_context
      end,
      'patient' => { 'type' => 'string', 'description' => PATIENT_DESCRIPTION },
      'relation' => { 'type' => 'string', 'enum' => Captain::Runtime::PartRegistry::RELATIONS, 'description' => RELATION_DESCRIPTION }
    }
  end

  def link_properties
    properties = {
      'object_refs' => { 'type' => 'array', 'description' => OBJECT_REFS_DESCRIPTION,
                         'items' => {
                           'type' => 'object', 'additionalProperties' => false,
                           'properties' => { 'type' => { 'type' => 'string' }, 'id' => { 'type' => 'integer', 'minimum' => 1 } },
                           'required' => %w[type id]
                         } },
      'link_part_id' => { 'type' => %w[string integer null], 'description' => LINK_PART_DESCRIPTION },
      'link_action' => { 'type' => 'string', 'enum' => Captain::Runtime::PartRegistry::LINK_ACTIONS, 'description' => LINK_ACTION_DESCRIPTION }
    }
    return properties unless @planning_context

    open = Captain::Runtime::PartRegistry.listed_parts(@planning_context)
    return properties.except('link_part_id', 'link_action') if open.empty?

    numbers = open.map { |part| Captain::Runtime::PartRegistry.number_of(Array(@planning_context[:parts]), part['id']) }
    properties['link_part_id']['enum'] = numbers.flat_map { |number| [number, number.to_s] } + [nil]
    properties
  end

  def rejected(message, retryable:, reason: nil)
    audit = { failure_stage: 'tool_arguments', mutation_executed: false }
    audit[:failure_reason] = reason if reason
    Captain::ToolResult.failure(error: message, retryable: retryable, audit: audit)
  end

  # What the model planned, for the audit log: the ToolTrace of a benchmark turn reads the arguments of a call from it. Monitoring
  # never changes the reply, so a failure to write is dropped.
  def audit(tool_context, arguments, result)
    context = tool_context.run_context.context
    state = context[:state].to_h
    assistant = Captain::Assistant.find_by(id: state[:assistant_id], **{ account_id: state[:account_id] }.compact)
    return unless assistant

    Captain::ToolExecutionAuditService.record(
      assistant: assistant, scope_name: Captain::ToolAccess::SCOPE_AGENT, tool_definition: AUDIT_TOOL, arguments: arguments,
      result: result, runtime_context: audit_context(state, context)
    )
  rescue StandardError
    nil
  end

  def audit_parts(parts)
    return parts unless parts.is_a?(Array)

    parts.map { |part| part.is_a?(Hash) ? part.transform_keys { |key| AUDIT_KEYS.fetch(key.to_s, key) } : part }
  end

  def audit_context(state, context)
    conversation = state[:conversation].to_h
    { conversation_id: conversation[:id], conversation_display_id: conversation[:display_id], source: state[:source],
      current_agent: context[:current_agent] }.compact
  end

  # The model links a part by the number it is listed with (#3); the registry stores the exact id. A reference that points at no
  # stored part is refused here, as the registry refuses a part that is not open, so that the model is told what is wrong with
  # the link and not, for example, that a council needs a second agent.
  def with_part_ids(parts, context)
    return parts unless parts.is_a?(Array)

    parts.map { |part| part.is_a?(Hash) ? with_part_id(part, context, single: parts.one?) : part }
  end

  def with_part_id(part, context, single: false)
    key = part.key?(:link_part_id) ? :link_part_id : 'link_part_id'
    return part if part[key].blank?

    registry = Captain::Runtime::PartRegistry
    id = registry.part_id_for(context[:parts], part[key])
    raise ArgumentError, registry.unknown_link_message(context, part[key]) unless Array(context[:parts]).any? { |item| item['id'] == id }

    updated = part.merge(key => id)
    if single && context&.dig(:captain_v2_current_input).present?
      full_input = Captain::Runtime::CouncilEditor.customer_text(context[:captain_v2_current_input]).strip
      f_key = updated.key?(:fragment) ? :fragment : 'fragment'
      updated = updated.merge(f_key => full_input) if full_input.present?
    end
    updated
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
