# frozen_string_literal: true

require 'digest'
require 'json_schemer'

class Captain::Runtime::ToolWrapper
  class InvalidToolArgumentsError < ArgumentError; end

  TOOL_NOT_BOUND_ERROR = 'Tool is not available for the current agent runtime'
  PARALLEL_MUTATING_TOOL_ERROR = 'Only one action tool can run per assistant tool-call batch'
  TECHNICAL_STOP_MESSAGE = 'A technical failure ended this run; staff take over the conversation. Write nothing to the customer.'
  DUPLICATE_FAILED_TOOL_ERROR = 'This exact tool call already failed. Change the arguments or stop retrying it.'
  TOOL_RESULT_CACHE_KEY = :captain_v2_tool_result_cache
  TOOL_FAILURE_CACHE_KEY = :captain_v2_tool_failure_cache
  TOOL_ATTEMPT_COUNTS_KEY = :captain_v2_tool_attempt_counts
  TOOL_REQUEST_COUNTS_KEY = Captain::Runtime::ToolLoopGuard::REQUEST_COUNTS_KEY
  TERMINAL_TOOL_STOP_KEY = Captain::Runtime::ToolLoopGuard::TERMINAL_STOP_KEY
  MUTATING_TOOL_EXECUTIONS_KEY = :captain_v2_mutating_tool_executions
  COMPLETED_ACTIONS_KEY = :captain_v2_completed_actions
  SERVICE_SPECIFIC_SCHEDULING_KEY = :captain_v2_service_specific_scheduling
  NULL_SENTINEL_ARGUMENT_KEYS = {
    'search_conversations' => %i[status priority].freeze
  }.freeze
  NON_SEMANTIC_FAILURE_ARGUMENT_KEYS = {
    'get_channel_health' => %i[limit].freeze,
    'list_campaigns' => %i[limit].freeze,
    'list_captain_knowledge_documents' => %i[limit].freeze,
    'list_captain_knowledge_entries' => %i[limit].freeze,
    'list_captain_scenarios' => %i[limit].freeze,
    'list_channel_templates' => %i[limit].freeze,
    'list_scheduling_resources' => %i[limit].freeze,
    'search_appointments' => %i[limit].freeze,
    'search_articles' => %i[limit].freeze,
    'search_available_slots' => %i[limit].freeze,
    'search_conversations' => %i[limit].freeze,
    'search_deals' => %i[limit].freeze,

    'search_scheduling_resources' => %i[limit].freeze,
    'search_tasks' => %i[limit].freeze
  }.freeze
  TERMINAL_FAILURE_REASONS = %w[duplicate_failed_tool_call handoff_not_authorized mutation_retry_blocked].freeze
  MAX_IDENTICAL_TOOL_EXECUTIONS = 3
  MAX_TOOL_EXECUTIONS_PER_TOOL = 12
  MAX_TOOL_REQUESTS_PER_TOOL = Captain::Runtime::ToolLoopGuard::MAX_REQUESTS_PER_TOOL
  MAX_TOOL_REQUESTS_PER_RUN = Captain::Runtime::ToolLoopGuard::MAX_REQUESTS_PER_RUN

  def initialize(tool, context_wrapper)
    @tool = tool
    @context_wrapper = context_wrapper
    @name = tool.name
    @description = agent_text_override&.description || tool.description
  end

  def call(args)
    ensure_response_run_current!
    if context_wrapper_context[:pending_handoff] || context_wrapper_context[:pending_human_handoff] ||
       context_wrapper_context[:pending_response_cancellation] || context_wrapper_context[:technical_failure]
      return RubyLLM::Tool::Halt.new('Control has been transferred; remaining calls in this batch were not executed.')
    end
    @operation_scope = Captain::Runtime::TaskQueue.new(context_wrapper_context).operation_scope if context_wrapper_context[:agent_session]
    @operation_target = nil
    normalized_args = normalize_args(args)
    @operation_target = Captain::Runtime::OperationTarget.of(@tool.name, normalized_args)

    request_stop = requested_tool_stop_result(normalized_args)
    return complete_and_halt(request_stop) if request_stop

    early_result = early_tool_result(normalized_args)
    return complete_and_halt(early_result) if terminal_early_result?(early_result)
    return complete_and_render(early_result) if early_result

    attempt_error = register_tool_execution_attempt(normalized_args)
    return complete_and_halt(attempt_error) if attempt_error

    execute_registered_tool(normalized_args)
  rescue Captain::Conversation::ControlGenerationStaleError
    raise
  rescue InvalidToolArgumentsError => e
    invalid_tool_arguments_result(e)
  rescue StandardError => e
    handle_execution_error(e)
  end

  def name
    @name || @tool.name
  end

  def description
    @description || @tool.description
  end

  def parameters
    @tool.parameters
  end

  # The schema the model sees: the tool's own schema with the agent text override applied (short English parameter texts, hidden
  # parameters removed). Arguments are validated against validation_params_schema, which keeps the hidden parameters.
  def params_schema
    @params_schema ||= agent_params_schema(validation_params_schema)
  end

  def provider_params
    params = @tool.respond_to?(:provider_params) ? @tool.provider_params.to_h.deep_symbolize_keys : {}
    strict_mode = provider_strict_mode
    return params if strict_mode.nil?

    params.deep_merge(function: { strict: strict_mode })
  end

  def metadata
    return @tool.send(:metadata) if @tool.respond_to?(:metadata, true)
    return @tool.send(:tool_definition) if @tool.respond_to?(:tool_definition, true)
    return @tool.send(:to_tool_metadata) if @tool.respond_to?(:to_tool_metadata, true)

    {}
  end

  alias tool_definition metadata

  def to_s
    name
  end

  private

  def ensure_response_run_current!
    state = @context_wrapper.context[:state] || {}
    fence = state[:captain_response_fence] || state['captain_response_fence']
    return if fence.blank?

    assistant_id = state[:assistant_id] || state['assistant_id']
    assistant = Captain::Assistant.find_by(id: assistant_id)
    Captain::Conversation::RunFenceService.new(assistant: assistant, state: state).ensure_current!
  end

  def execute_registered_tool(normalized_args)
    @operation_guard = Captain::Runtime::OperationGuard.new(context_wrapper_context, @tool, normalized_args, scope: @operation_scope)
    existing = @operation_guard.reserve
    return complete_and_halt(existing) if terminal_early_result?(existing)
    return complete_and_render(existing) if existing

    tool_context = Captain::Runtime::ToolContext.new(run_context: @context_wrapper)
    @context_wrapper.callback_manager.emit_tool_start(@tool.name, normalized_args, @context_wrapper)
    track_mutating_tool_execution(normalized_args)
    execute_tool(tool_context, normalized_args)
  end

  # An exception of a tool (or of the code around it) is an internal failure: the run ends and staff take over.
  def handle_execution_error(error)
    record_mutating_tool_result(Captain::ToolResult.failure(error: error, retryable: false))
    register_technical_failure('tool' => Captain::Runtime::ToolFailure.canonical_name(@tool.name), 'kind' => Captain::Runtime::ToolFailure::TECHNICAL,
                               'reason' => 'exception', 'error_class' => error.class.name)
    @context_wrapper.callback_manager.emit_tool_complete(
      @tool.name,
      Captain::ToolResult.failure(error: error),
      @context_wrapper
    )
    raise error
  end

  def early_tool_result(normalized_args)
    pre_execution_error(normalized_args) ||
      reserve_mutating_tool_call(normalized_args) ||
      repeated_failed_tool_result(normalized_args) ||
      cached_mutating_tool_result(normalized_args) ||
      repeated_mutating_tool_result(normalized_args)
  end

  def reserve_mutating_tool_call(normalized_args)
    return unless mutating_tool? && current_tool_batch_id.present?

    @context_wrapper.mutating_tool_guard.synchronize do
      error = parallel_mutating_tool_error
      next error if error

      remember_mutating_tool_call(normalized_args)
      nil
    end
  end

  def execute_tool(tool_context, normalized_args)
    result = Captain::Playground::ExecutionBoundary.execute(@tool, tool_context, normalized_args) do
      @tool.execute(tool_context, **normalized_args)
    end
    result_error = tool_safety_error_for(:tool_results, safety_checked_result(result))
    final_result = result_error || result
    @operation_guard&.finish(final_result) unless halt_result?(final_result)
    cache_successful_mutating_tool_result(normalized_args, final_result)
    cache_non_retryable_failure(normalized_args, final_result)
    record_mutating_tool_result(final_result)
    record_completed_action(final_result)
    @context_wrapper.callback_manager.emit_tool_complete(@tool.name, final_result, @context_wrapper)
    return final_result if halt_result?(final_result)

    technical_stop = technical_failure_halt(final_result)
    return technical_stop if technical_stop
    return halt_completed_result(final_result) if terminal_failure_result?(final_result)

    Captain::ToolResult.render(final_result)
  end

  # A technical failure of a tool (the provider rejected the call or did not answer, a timeout, an unknown outcome; see
  # ToolFailure) ends the run at once. The customer gets no text about it: the conversation goes to staff, who are told what
  # failed. A business outcome (a taken slot, a patient who was not found, an argument to fix) is rendered to the agent as before.
  def technical_failure_halt(result)
    return unless reportable_failure_tool? && Captain::Runtime::ToolFailure.technical?(result)

    register_technical_failure(Captain::Runtime::ToolFailure.summary(@tool.name, result))
    RubyLLM::Tool::Halt.new(TECHNICAL_STOP_MESSAGE)
  end

  # The names of the actions this run has performed (a successful write that is not an annotation): staff are told which of them
  # came before a failure.
  def record_completed_action(result)
    return unless domain_mutating_tool? && reportable_failure_tool? && !halt_result?(result)
    return if Captain::Runtime::ToolFailure.annotation_tool?(@tool.name) || Captain::Runtime::ToolFailure.failure?(result)

    (context_wrapper_context[COMPLETED_ACTIONS_KEY] ||= []) << Captain::Runtime::ToolFailure.canonical_name(@tool.name)
  end

  # The first failure of a run is the one that is reported. The record holds names and codes only, never arguments or messages.
  def register_technical_failure(summary)
    return unless reportable_failure_tool?
    return if context_wrapper_context[:technical_failure].present?

    context_wrapper_context[:technical_failure] = summary.merge('mutating' => mutating_tool?)
    Captain::Runtime::CoordinationEvents.technical_failure(context: context_wrapper_context, failure: context_wrapper_context[:technical_failure])
  end

  # The tools that move the conversation (a transfer, the plan, the task queue, the human handoff, the resolution, a cancelled
  # reply) are not business tools: what they report is not a failure of the work for the customer. A Playground run has no
  # customer and no staff to hand over to: the failures of its simulated tools are scenario outcomes that the person who tests
  # sees as they are.
  def reportable_failure_tool?
    !coordination_tool? && !terminal_control_tool? && !@tool.is_a?(Captain::Tools::CancelResponseTool) &&
      context_wrapper_context[:playground_session].nil?
  end

  def invalid_tool_arguments_result(error)
    normalized_args = {}
    request_stop = requested_tool_stop_result(normalized_args)
    return complete_and_halt(request_stop) if request_stop

    complete_and_render(
      Captain::ToolResult.failure(
        error: error.message,
        retryable: false,
        audit: { failure_stage: 'tool_arguments', failure_reason: 'invalid_tool_arguments' }
      )
    )
  end

  def normalize_args(args)
    return {} if args.nil?

    raise InvalidToolArgumentsError, 'Tool arguments must be an object' unless args.respond_to?(:to_h)

    raw_args = args.to_h
    raise InvalidToolArgumentsError, 'Tool arguments must be an object' unless raw_args.is_a?(Hash)

    normalized = raw_args.deep_symbolize_keys
    normalized = normalized_tool_call_envelope(normalized)

    normalized = unwrap_nested_tool_call_envelopes(normalized)
    normalized = omit_null_sentinel_arguments(normalized)
    normalized = omit_hidden_arguments(normalized)
    normalized = normalize_tool_specific_arguments(normalized)
    validate_normalized_args!(normalized)
    normalized
  rescue InvalidToolArgumentsError
    raise
  rescue StandardError => e
    raise InvalidToolArgumentsError, "Tool arguments are invalid: #{e.message}"
  end

  def normalized_tool_call_envelope(args)
    return args unless args[:name].present? && args.key?(:parameters)
    raise InvalidToolArgumentsError, 'Tool call parameters must be an object' unless args[:parameters].is_a?(Hash)

    args[:parameters].deep_symbolize_keys
  end

  def unwrap_nested_tool_call_envelopes(args)
    args.each_with_object({}) do |(key, value), normalized|
      normalized[key] = nested_tool_call_parameter_value(key, value)
    end
  end

  def nested_tool_call_parameter_value(key, value)
    return value unless value.is_a?(Hash)

    parameters = value.with_indifferent_access[:parameters]
    return value unless parameters.is_a?(Hash)

    parameters.with_indifferent_access.fetch(key, value)
  end

  def omit_null_sentinel_arguments(args)
    keys = NULL_SENTINEL_ARGUMENT_KEYS.fetch(@tool.name.to_s, [])
    args.except(*keys.select { |key| null_sentinel?(args[key]) })
  end

  def normalize_tool_specific_arguments(args)
    return args unless @tool.respond_to?(:normalize_runtime_arguments)

    @tool.normalize_runtime_arguments(args, context: context_wrapper_context)
  end

  def null_sentinel?(value)
    value.is_a?(String) && %w[nil null undefined].include?(value.strip.downcase)
  end

  def raw_params_schema
    @tool.respond_to?(:params_schema) ? @tool.params_schema : nil
  end

  def validation_params_schema
    @validation_params_schema ||= schema_with_positive_id_constraints(raw_params_schema)
  end

  # Short English tool texts of the customer-facing agent runtime (config/captain/agent_tool_texts.yml). Only the built-in
  # registry tools take them: a custom HTTP tool, an MCP tool or a skill script keeps the text its author wrote, whatever its
  # name is.
  def agent_text_override
    return @agent_text_override if defined?(@agent_text_override)

    @agent_text_override = built_in_registry_tool? ? Captain::Runtime::AgentToolTexts.for_tool(@name) : nil
  end

  def built_in_registry_tool?
    return true if @tool.is_a?(Captain::Tools::Agent::AccountToolAdapter)

    @tool.is_a?(Captain::Tools::BasePublicTool) &&
      !@tool.is_a?(Captain::Tools::McpTool) && !@tool.is_a?(Captain::Tools::SkillScriptTool)
  end

  def agent_params_schema(schema)
    override = agent_text_override
    return schema if override.nil? || !schema.is_a?(Hash)

    result = schema.deep_dup
    properties = result['properties']
    return result unless properties.is_a?(Hash)

    override.params.each do |param_name, text|
      properties[param_name]['description'] = text if properties[param_name].is_a?(Hash)
    end
    hidden = override.hidden_params
    properties.except!(*hidden)
    result['required'] = Array(result['required']).map(&:to_s) - hidden if result.key?('required')
    result
  end

  def omit_hidden_arguments(args)
    hidden = agent_text_override&.hidden_params
    return args if hidden.blank?

    args.except(*hidden.map(&:to_sym))
  end

  def schema_with_positive_id_constraints(schema)
    return schema unless schema.is_a?(Hash)

    normalized = schema.deep_stringify_keys.deep_dup
    normalized.delete('strict')
    required_names = Array(normalized['required']).map(&:to_s)
    normalized.fetch('properties', {}).each do |name, property_schema|
      normalize_property_schema!(name, property_schema, required_names)
    end
    normalized
  end

  # An omitted optional value, an unverified id and the other global argument rules are stated once in the system prompt; the
  # schema only carries the shape: a null is accepted for an optional value and an id is at least 1.
  def normalize_property_schema!(name, property_schema, required_names)
    allow_explicit_null!(property_schema) unless required_names.include?(name.to_s)
    if positive_id_schema?(name, property_schema)
      constrain_reference_schema!(property_schema)
    elsif id_array_schema?(name, property_schema)
      item_schema = property_schema['items']
      constrain_reference_schema!(item_schema) if Array(item_schema['type']).intersect?(%w[integer number])
    end
  end

  def constrain_reference_schema!(schema)
    unless playground_session
      schema['minimum'] = [schema['minimum'].to_i, 1].max
      return
    end

    # Keep the production tool shape and integer type. Only a server-bound
    # Playground can additionally use negative references, checked before call.
    schema.delete('minimum')
    schema['anyOf'] = [{ 'minimum' => 1 }, { 'maximum' => -1 }]
  end

  def playground_session
    session = context_wrapper_context[:playground_session]
    return unless session.is_a?(Captain::Playground::Session)

    session.assert_context!(context_wrapper_context[:state])
    session
  end

  def allow_explicit_null!(property_schema)
    property_types = Array(property_schema['type']).map(&:to_s)
    return if property_types.empty?

    property_schema['type'] = (property_types | ['null'])
  end

  def provider_strict_mode
    schema = raw_params_schema
    return unless schema.is_a?(Hash)

    normalized = schema.deep_stringify_keys
    return unless normalized.key?('strict')

    required_names = Array(normalized['required']).map(&:to_s)
    optional_names = normalized.fetch('properties', {}).keys.map(&:to_s) - required_names
    return false if optional_names.any?

    ActiveModel::Type::Boolean.new.cast(normalized['strict'])
  end

  def positive_id_schema?(name, property_schema)
    return false unless name.to_s.end_with?('_id')
    return false unless property_schema.is_a?(Hash)

    Array(property_schema['type']).intersect?(%w[integer number])
  end

  def id_array_schema?(name, property_schema)
    return false unless name.to_s.end_with?('_ids')
    return false unless property_schema.is_a?(Hash) && property_schema['items'].is_a?(Hash)

    Array(property_schema['type']).include?('array')
  end

  def validate_normalized_args!(args)
    playground_session&.namespace&.decode(args)
    schema = validation_params_schema
    return unless schema.is_a?(Hash)

    error = JSONSchemer.schema(schema).validate(args.deep_stringify_keys).first
    return if error.blank?

    pointer = error['data_pointer'].presence || '/'
    error_type = error['type'].presence || 'schema violation'
    raise InvalidToolArgumentsError, "Invalid tool arguments at #{pointer}: #{error_type}#{allowed_values_note(error)}"
  end

  # A value outside an enum is told with the values the schema allows, so that the model can correct the call.
  def allowed_values_note(error)
    allowed = error['schema'].is_a?(Hash) ? error['schema']['enum'] : nil
    allowed.is_a?(Array) && error['type'] == 'enum' ? " (allowed: #{allowed.first(12).map(&:to_s).join(', ')})" : ''
  end

  # An agent's own actions (booking, rescheduling, card updates, the human handoff) and its transfer of the conversation to one
  # colleague (HandoffTool) need no request plan: the plan only coordinates several agents (councils, answers to open parts).
  # The owner of a council part acts with its own tools in the same way, so nothing here looks at the part.
  def pre_execution_error(normalized_args)
    bound_tool_error_for_current_agent ||
      tool_safety_error_for(:tool_arguments, normalized_args) ||
      scheduling_context_error(normalized_args)
  end

  def scheduling_context_error(normalized_args)
    return unless canonical_tool_name == 'search_available_slots'

    @context_wrapper.tool_loop_guard_mutex.synchronize do
      return remember_service_specific_scheduling! if positive_service_id?(normalized_args[:service_id])
      return unless service_specific_scheduling?

      publish_generic_after_service_specific_attempt
      return unless scheduling_grounding_guard_enabled?

      Captain::ToolResult.failure(
        error: 'Service-specific availability requires a confirmed service_id.',
        data: { code: 'service_context_required' },
        retryable: false,
        audit: {
          failure_stage: 'tool_arguments',
          failure_reason: 'service_context_required',
          tool_name: canonical_tool_name,
          provider_call_blocked: true
        }
      )
    end
  end

  def positive_service_id?(value)
    return true if value.present? && value.to_i.positive?
    return false unless value.present? && value.to_i.negative? && playground_session

    local_id = playground_session.namespace.decode({ service_id: value }).fetch(:service_id)
    playground_session.scenario.data['services'].any? { |item| item['id'] == local_id && item['active'] }
  end

  def remember_service_specific_scheduling!
    context_wrapper_context[SERVICE_SPECIFIC_SCHEDULING_KEY] = true
    nil
  end

  def service_specific_scheduling?
    ActiveModel::Type::Boolean.new.cast(context_wrapper_context[SERVICE_SPECIFIC_SCHEDULING_KEY])
  end

  def scheduling_grounding_guard_enabled?
    state = context_wrapper_context[:state].to_h.with_indifferent_access
    ActiveModel::Type::Boolean.new.cast(state[:captain_scheduling_grounding_guard_enabled])
  end

  def canonical_tool_name
    name = @tool.name.to_s
    %w[search_available_slots search_scheduling_resources search_scheduling_services].find do |candidate|
      name == candidate || name.end_with?("__#{candidate}") || name.end_with?(":#{candidate}")
    end || name
  end

  def publish_generic_after_service_specific_attempt
    state = context_wrapper_context[:state].to_h.with_indifferent_access
    Llm::EventBus.publish(
      'captain.generic_after_service_specific_attempt',
      feature: 'assistant',
      runtime_mode: 'captain_runtime',
      account_id: state[:account_id],
      conversation_id: state.dig(:conversation, :id),
      tool_name: canonical_tool_name,
      enforced: scheduling_grounding_guard_enabled?,
      provider_call_blocked: scheduling_grounding_guard_enabled?
    )
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][ToolWrapper] Failed to publish scheduling context block: #{e.class}: #{e.message}")
  end

  def complete_and_render(result)
    @context_wrapper.callback_manager.emit_tool_complete(@tool.name, result, @context_wrapper)
    Captain::ToolResult.render(result)
  end

  def complete_and_halt(result)
    normalized_result = Captain::ToolResult.normalize(result, retryable: false)
    @context_wrapper.callback_manager.emit_tool_complete(@tool.name, normalized_result, @context_wrapper)
    halt_completed_result(normalized_result)
  end

  def halt_completed_result(result)
    normalized_result = Captain::ToolResult.normalize(result, retryable: false)
    remember_terminal_tool_stop(normalized_result)
    RubyLLM::Tool::Halt.new(Captain::ToolResult.render(normalized_result))
  end

  def emit_tool_requested(normalized_args)
    @context_wrapper.callback_manager.emit_tool_requested(@tool.name, normalized_args, @context_wrapper)
  end

  def requested_tool_stop_result(normalized_args)
    emit_tool_requested(normalized_args)
    request_error = register_tool_request(normalized_args)

    existing_terminal_tool_stop_result || request_error
  end

  def terminal_early_result?(result)
    terminal_failure_result?(result)
  end

  def terminal_failure_result?(result)
    return false if result.blank? || halt_result?(result)

    failure_reason = Captain::ToolResult.normalize(result).dig(:audit, :failure_reason).to_s
    failure_reason.in?(TERMINAL_FAILURE_REASONS)
  end

  def terminal_tool_stop?
    existing_terminal_tool_stop_result.present?
  end

  def existing_terminal_tool_stop_result
    tool_loop_guard.terminal_result
  end

  def remember_terminal_tool_stop(result)
    tool_loop_guard.stop!(result)
  end

  def bound_tool_error_for_current_agent
    return nil unless enforce_bound_tools?

    bound_ids = bound_tool_ids_for_current_agent
    return nil if bound_ids.include?(@tool.name.to_s)

    Captain::ToolResult.failure(
      error: TOOL_NOT_BOUND_ERROR, retryable: false,
      audit: { failure_stage: 'tool_execution', failure_reason: 'tool_not_bound', mutation_executed: false }
    )
  end

  def enforce_bound_tools?
    context = @context_wrapper.context
    ActiveModel::Type::Boolean.new.cast(context[:captain_v2_bound_tool_gate] || context['captain_v2_bound_tool_gate']) ||
      context.key?(:captain_v2_bound_tool_ids_by_agent) ||
      context.key?('captain_v2_bound_tool_ids_by_agent') ||
      context.key?(:captain_v2_bound_tool_ids) ||
      context.key?('captain_v2_bound_tool_ids')
  end

  def bound_tool_ids_for_current_agent
    context = @context_wrapper.context
    by_agent = bound_tool_ids_by_agent
    current_agent = context[:current_agent] || context['current_agent']
    return normalize_bound_tool_ids(by_agent[current_agent.to_s]) if current_agent.present? && by_agent.key?(current_agent.to_s)
    return [] if current_agent.present? && by_agent.present?

    normalize_bound_tool_ids(context[:captain_v2_bound_tool_ids] || context['captain_v2_bound_tool_ids'])
  end

  def bound_tool_ids_by_agent
    (context_wrapper_context[:captain_v2_bound_tool_ids_by_agent] ||
      context_wrapper_context['captain_v2_bound_tool_ids_by_agent'] ||
      {}).with_indifferent_access
  end

  def normalize_bound_tool_ids(bound_ids)
    Array(bound_ids).filter_map { |tool_id| tool_id.to_s.presence }
  end

  def context_wrapper_context
    @context_wrapper.context
  end

  def cached_mutating_tool_result(normalized_args)
    return unless cache_mutating_tool_results?

    cached_entry = tool_result_cache[tool_result_cache_digest(normalized_args)]
    return unless cached_entry.respond_to?(:[])

    result = cached_entry[:result] || cached_entry['result']
    return unless result.respond_to?(:to_h)

    cached_normalized = result.to_h.deep_symbolize_keys
    cached_normalized[:audit] = cached_normalized.fetch(:audit, {}).to_h.merge(cached_result_reused: true)
    cached_normalized
  rescue StandardError
    nil
  end

  def cache_successful_mutating_tool_result(normalized_args, result)
    return unless cache_mutating_tool_results?
    return if halt_result?(result)

    normalized_result = Captain::ToolResult.normalize(result)
    return if Captain::ToolResult.error?(normalized_result)

    tool_result_cache[tool_result_cache_digest(normalized_args)] = {
      tool_name: @tool.name.to_s,
      arguments: normalized_args.deep_dup,
      result: normalized_result.deep_dup,
      stored_at: Time.current.iso8601
    }
  rescue StandardError
    nil
  end

  def repeated_failed_tool_result(normalized_args)
    cached_entry = tool_failure_cache[semantic_tool_call_digest(normalized_args)]
    return if cached_entry.blank?

    Captain::ToolResult.failure(
      error: DUPLICATE_FAILED_TOOL_ERROR,
      retryable: false,
      audit: {
        failure_stage: 'tool_execution',
        failure_reason: 'duplicate_failed_tool_call',
        original_error: cached_entry[:error] || cached_entry['error']
      }.compact
    )
  end

  def cache_non_retryable_failure(normalized_args, result)
    normalized_result = Captain::ToolResult.normalize(result)
    return unless Captain::ToolResult.error?(normalized_result)
    return if normalized_result[:retryable]

    tool_failure_cache[semantic_tool_call_digest(normalized_args)] = {
      error: normalized_result[:error],
      stored_at: Time.current.iso8601
    }
  rescue StandardError
    nil
  end

  def tool_result_cache
    context_wrapper_context[TOOL_RESULT_CACHE_KEY] ||= {}
  end

  def tool_failure_cache
    context_wrapper_context[TOOL_FAILURE_CACHE_KEY] ||= {}
  end

  def register_tool_execution_attempt(normalized_args)
    attempt_key = coordination_tool? ? @tool.name.to_s : mutation_execution_key
    counts = tool_attempt_counts.fetch(attempt_key) { { total: 0, by_signature: {} } }
    signature = tool_result_cache_digest(normalized_args)
    signature_count = counts[:by_signature].fetch(signature, 0)
    execution_limit = coordination_tool? ? Captain::Runtime::ToolLoopGuard::MAX_COORDINATION_REQUESTS : MAX_TOOL_EXECUTIONS_PER_TOOL
    return tool_attempt_limit_result(counts, signature_count) if counts[:total] >= execution_limit ||
                                                                 signature_count >= MAX_IDENTICAL_TOOL_EXECUTIONS

    counts[:total] += 1
    counts[:by_signature][signature] = signature_count + 1
    tool_attempt_counts[attempt_key] = counts
    nil
  end

  def tool_attempt_limit_result(counts, signature_count)
    Captain::ToolResult.failure(
      error: 'Tool execution attempt limit reached. Change the arguments or stop calling this tool.',
      retryable: false,
      audit: {
        failure_stage: 'tool_execution',
        failure_reason: 'tool_attempt_limit',
        total_attempts: counts[:total],
        identical_attempts: signature_count
      }
    )
  end

  def tool_attempt_counts
    context_wrapper_context[TOOL_ATTEMPT_COUNTS_KEY] ||= {}
  end

  def register_tool_request(normalized_args)
    tool_loop_guard.register_request(signature: tool_result_cache_digest(normalized_args))
  end

  def tool_loop_guard
    Captain::Runtime::ToolLoopGuard.new(
      @context_wrapper, @tool.name, coordination: coordination_tool? || terminal_control_tool?, task_scope: task_operation_scope
    )
  end

  def repeated_mutating_tool_result(normalized_args)
    return unless domain_mutating_tool?

    entry = mutating_tool_executions[mutation_claim_key]
    return if entry.blank? || mutation_retry_allowed?(entry, normalized_args)

    Captain::ToolResult.failure(
      error: 'This action tool already ran in the current assistant run. Do not retry it with alternate arguments.',
      retryable: false,
      audit: { failure_stage: 'tool_execution', failure_reason: 'mutation_retry_blocked' }
    )
  end

  def mutation_retry_allowed?(entry, normalized_args)
    return true if entry[:safe_to_correct] && entry[:arguments_digest] != tool_result_cache_digest(normalized_args)

    idempotency_key = normalized_args[:idempotency_key].presence
    entry[:retryable] == true && idempotency_key.present? && entry[:idempotency_key] == idempotency_key
  end

  def track_mutating_tool_execution(normalized_args)
    return unless domain_mutating_tool?

    mutating_tool_executions[mutation_claim_key] = {
      arguments_digest: tool_result_cache_digest(normalized_args),
      idempotency_key: normalized_args[:idempotency_key].presence,
      retryable: false
    }
  end

  def record_mutating_tool_result(result)
    entry = mutating_tool_executions[mutation_claim_key]
    return if entry.blank?

    normalized_result = Captain::ToolResult.normalize(result)
    entry[:retryable] = normalized_result[:retryable] == true
    entry[:failure_stage] = normalized_result.dig(:audit, :failure_stage).to_s.presence
    entry[:failure_reason] = normalized_result.dig(:audit, :failure_reason).to_s.presence
    entry[:safe_to_correct] = unexecuted_argument_failure?(normalized_result) || Captain::Runtime::ToolFailure.business_answer?(result)
  rescue StandardError
    entry[:retryable] = false
  end

  # A call that changed nothing may be answered with a corrected call of the same tool in the same run: validation proved that
  # nothing began, or the tool gave a business answer (the slot is taken, the patient was not found, the time is outside working
  # hours) that the agent acts on by choosing another slot or by asking. A call that may have changed something stays claimed.
  def unexecuted_argument_failure?(normalized_result)
    normalized_result[:success] == false && normalized_result.dig(:audit, :mutation_executed) == false &&
      normalized_result.dig(:audit, :failure_stage) == 'tool_arguments'
  end

  def mutating_tool_executions
    context_wrapper_context[MUTATING_TOOL_EXECUTIONS_KEY] ||= {}
  end

  def tool_result_cache_digest(normalized_args)
    Digest::SHA256.hexdigest(JSON.generate(canonical_json_value({
      tool_name: @tool.name.to_s, arguments: normalized_args,
      actor_id: context_wrapper_context.dig(:state, :assistant_id),
      task_scope: task_operation_scope
    })))
  end

  def mutation_execution_key
    return @tool.name.to_s unless context_wrapper_context[:agent_session]

    "#{task_operation_scope}:#{@tool.name}"
  end

  # The claim of an action in a request: the tool, and the target of the call when it has one (the person a booking is for, the
  # appointment a change is for). A second call for another target is another operation; the same target with other arguments is
  # a retry, which the claim refuses.
  def mutation_claim_key
    [mutation_execution_key, @operation_target].compact.join(':')
  end

  def task_operation_scope
    return unless context_wrapper_context[:agent_session]

    @operation_scope || Captain::Runtime::TaskQueue.new(context_wrapper_context).operation_scope
  end

  def semantic_tool_call_digest(normalized_args)
    ignored_keys = mutating_tool? ? [] : NON_SEMANTIC_FAILURE_ARGUMENT_KEYS.fetch(@tool.name.to_s, [])
    semantic_args = normalized_args.except(*ignored_keys)
    tool_result_cache_digest(semantic_args)
  end

  def canonical_json_value(value)
    case value
    when Hash
      value.to_h.stringify_keys.sort.to_h.transform_values { |nested| canonical_json_value(nested) }
    when Array
      value.map { |nested| canonical_json_value(nested) }
    else
      value.respond_to?(:as_json) ? value.as_json : value
    end
  end

  def cache_mutating_tool_results?
    domain_mutating_tool?
  end

  def domain_mutating_tool?
    mutating_tool?
  end

  def mutating_tool?
    return false if coordination_tool?

    Llm::ToolRiskPolicy.mutating?(@tool)
  end

  def coordination_tool?
    @tool.is_a?(Captain::Runtime::HandoffTool) || @tool.is_a?(Captain::Runtime::TaskQueueTool) ||
      @tool.is_a?(Captain::Runtime::PartPlanTool)
  end

  def terminal_control_tool?
    @tool.is_a?(Captain::Tools::HandoffTool) || @tool.is_a?(Captain::Tools::ResolveConversationTool)
  end

  def parallel_mutating_tool_error
    return unless mutating_tool?
    return if current_tool_batch_id.blank?
    return if mutating_tool_calls_for_current_batch.blank?

    Captain::ToolResult.failure(
      error: PARALLEL_MUTATING_TOOL_ERROR,
      retryable: false,
      audit: {
        failure_stage: 'tool_arguments',
        failure_reason: 'parallel_mutating_tool_call',
        batch_id: current_tool_batch_id,
        existing_tool_calls: mutating_tool_calls_for_current_batch.pluck(:tool_name)
      }
    )
  end

  def remember_mutating_tool_call(normalized_args)
    return unless mutating_tool?
    return if current_tool_batch_id.blank?

    mutating_tool_calls_for_current_batch << {
      tool_name: @tool.name.to_s,
      arguments: normalized_args.deep_dup,
      started_at: Time.current.iso8601
    }
  rescue StandardError
    nil
  end

  def current_tool_batch_id
    context_wrapper_context[:captain_v2_current_tool_batch_id] ||
      context_wrapper_context['captain_v2_current_tool_batch_id']
  end

  def mutating_tool_calls_for_current_batch
    calls_by_batch = context_wrapper_context[:captain_v2_mutating_tool_calls_by_batch] ||
                     context_wrapper_context['captain_v2_mutating_tool_calls_by_batch']
    return [] unless calls_by_batch.respond_to?(:[])

    calls_by_batch[current_tool_batch_id] ||= []
  end

  def tool_safety_error_for(stage, content)
    case stage
    when :tool_arguments
      check_tool_arguments!(content)
    when :tool_results
      check_tool_results!(content)
    end

    nil
  rescue Llm::SafetyPolicy::UnsafeContentError, Llm::SafetyPolicy::UnavailableError => e
    Captain::ToolResult.failure(
      error: Captain::ToolSafety.blocked_message(stage: e.stage, error: e),
      retryable: false,
      audit: { failure_stage: e.stage.to_s, failure_reason: e.reason.to_s }
    )
  end

  # The runtime guardrails scan tool data only for external tools (see Captain::ToolSafety.external_tool?); built-in system
  # tools are skipped.
  def check_tool_arguments!(arguments)
    return unless external_content_tool?

    Captain::ToolSafety.check_arguments!(
      feature: :assistant,
      arguments: arguments,
      preferences: tool_data_preferences
    )
  end

  def check_tool_results!(result)
    return unless external_content_tool?

    Captain::ToolSafety.check_result!(
      feature: :assistant,
      result: result,
      preferences: tool_data_preferences
    )
  end

  def external_content_tool?
    return @external_content_tool unless @external_content_tool.nil?

    @external_content_tool = Captain::ToolSafety.external_tool?(@tool)
  end

  # Provider moderation (an LLM call) covers the customer input and the agent output, never tool data, so it is switched off
  # for these checks whatever the workspace chose for the input and output.
  def tool_data_preferences
    captain_runtime_preferences.to_h.merge('assistant_moderation' => false)
  end

  def captain_runtime_preferences
    @context_wrapper.context.dig(:state, :captain_runtime)
  end

  def halt_result?(result)
    defined?(RubyLLM::Tool::Halt) && result.is_a?(RubyLLM::Tool::Halt)
  end

  def safety_checked_result(result)
    return result.content if halt_result?(result)

    result
  end
end
