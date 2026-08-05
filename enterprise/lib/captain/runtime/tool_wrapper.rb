# frozen_string_literal: true

require 'digest'
require 'json_schemer'

class Captain::Runtime::ToolWrapper
  class InvalidToolArgumentsError < ArgumentError; end

  TOOL_NOT_BOUND_ERROR = 'Tool is not available for the current agent runtime'
  PARALLEL_MUTATING_TOOL_ERROR = 'Only one action tool can run per assistant tool-call batch'
  DUPLICATE_FAILED_TOOL_ERROR = 'This exact tool call already failed. Change the arguments or stop retrying it.'
  TOOL_RESULT_CACHE_KEY = :captain_v2_tool_result_cache
  TOOL_FAILURE_CACHE_KEY = :captain_v2_tool_failure_cache
  TOOL_ATTEMPT_COUNTS_KEY = :captain_v2_tool_attempt_counts
  TOOL_REQUEST_COUNTS_KEY = Captain::Runtime::ToolLoopGuard::REQUEST_COUNTS_KEY
  TERMINAL_TOOL_STOP_KEY = Captain::Runtime::ToolLoopGuard::TERMINAL_STOP_KEY
  MUTATING_TOOL_EXECUTIONS_KEY = :captain_v2_mutating_tool_executions
  VERIFIED_ID_DESCRIPTION = 'Use only an ID verified from the user, current context, or a prior tool result. Never guess an ID.'
  OPTIONAL_ARGUMENT_DESCRIPTION =
    'If this value was not explicitly provided or resolved, omit the key entirely; never invent a placeholder value.'
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
    'search_kaspi_pay_payments' => %i[limit].freeze,
    'search_scheduling_resources' => %i[limit].freeze,
    'search_tasks' => %i[limit].freeze
  }.freeze
  TERMINAL_FAILURE_REASONS = %w[duplicate_failed_tool_call mutation_retry_blocked].freeze
  MAX_IDENTICAL_TOOL_EXECUTIONS = 3
  MAX_TOOL_EXECUTIONS_PER_TOOL = 12
  MAX_TOOL_REQUESTS_PER_TOOL = Captain::Runtime::ToolLoopGuard::MAX_REQUESTS_PER_TOOL
  MAX_TOOL_REQUESTS_PER_RUN = Captain::Runtime::ToolLoopGuard::MAX_REQUESTS_PER_RUN

  def initialize(tool, context_wrapper)
    @tool = tool
    @context_wrapper = context_wrapper
    @name = tool.name
    @description = tool.description
  end

  def call(args)
    normalized_args = normalize_args(args)

    request_stop = requested_tool_stop_result(normalized_args)
    return complete_and_halt(request_stop) if request_stop

    early_result = early_tool_result(normalized_args)
    return complete_and_halt(early_result) if terminal_early_result?(early_result)
    return complete_and_render(early_result) if early_result

    attempt_error = register_tool_execution_attempt(normalized_args)
    return complete_and_halt(attempt_error) if attempt_error

    execute_registered_tool(normalized_args)
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

  def params_schema
    @params_schema ||= schema_with_positive_id_constraints(raw_params_schema)
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

  def execute_registered_tool(normalized_args)
    tool_context = Captain::Runtime::ToolContext.new(run_context: @context_wrapper)
    @context_wrapper.callback_manager.emit_tool_start(@tool.name, normalized_args, @context_wrapper)
    track_mutating_tool_execution(normalized_args)
    execute_tool(tool_context, normalized_args)
  end

  def handle_execution_error(error)
    record_mutating_tool_result(Captain::ToolResult.failure(error: error, retryable: false))
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
    result = @tool.execute(tool_context, **normalized_args)
    result_error = tool_safety_error_for(:tool_results, safety_checked_result(result))
    final_result = result_error || result
    cache_successful_mutating_tool_result(normalized_args, final_result)
    cache_non_retryable_failure(normalized_args, final_result)
    record_mutating_tool_result(final_result)
    @context_wrapper.callback_manager.emit_tool_complete(@tool.name, final_result, @context_wrapper)
    return final_result if halt_result?(final_result)

    Captain::ToolResult.render(final_result)
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

  def normalize_property_schema!(name, property_schema, required_names)
    unless required_names.include?(name.to_s)
      allow_explicit_null!(property_schema)
      append_optional_argument_description!(property_schema)
    end
    if positive_id_schema?(name, property_schema)
      property_schema['minimum'] = [property_schema['minimum'].to_i, 1].max
      append_verified_id_description!(property_schema)
    elsif id_array_schema?(name, property_schema)
      item_schema = property_schema['items']
      item_schema['minimum'] = [item_schema['minimum'].to_i, 1].max if Array(item_schema['type']).intersect?(%w[integer number])
      append_verified_id_description!(property_schema)
    end
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

  def append_optional_argument_description!(property_schema)
    existing_description = property_schema['description'].to_s.strip
    return if existing_description.include?(OPTIONAL_ARGUMENT_DESCRIPTION)

    property_schema['description'] = [existing_description.presence, OPTIONAL_ARGUMENT_DESCRIPTION].compact.join(' ')
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

  def append_verified_id_description!(property_schema)
    existing_description = property_schema['description'].to_s.strip
    return if existing_description.include?(VERIFIED_ID_DESCRIPTION)

    property_schema['description'] = [existing_description.presence, VERIFIED_ID_DESCRIPTION].compact.join(' ')
  end

  def validate_normalized_args!(args)
    schema = params_schema
    return unless schema.is_a?(Hash)

    error = JSONSchemer.schema(schema).validate(args.deep_stringify_keys).first
    return if error.blank?

    pointer = error['data_pointer'].presence || '/'
    error_type = error['type'].presence || 'schema violation'
    raise InvalidToolArgumentsError, "Invalid tool arguments at #{pointer}: #{error_type}"
  end

  def pre_execution_error(normalized_args)
    bound_tool_error_for_current_agent ||
      tool_safety_error_for(:tool_arguments, normalized_args)
  end

  def complete_and_render(result)
    @context_wrapper.callback_manager.emit_tool_complete(@tool.name, result, @context_wrapper)
    Captain::ToolResult.render(result)
  end

  def complete_and_halt(result)
    normalized_result = Captain::ToolResult.normalize(result, retryable: false)
    @context_wrapper.callback_manager.emit_tool_complete(@tool.name, normalized_result, @context_wrapper)
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
    return false if result.blank?

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

    Captain::ToolResult.failure(error: TOOL_NOT_BOUND_ERROR, retryable: false)
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
    counts = tool_attempt_counts.fetch(@tool.name.to_s) { { total: 0, by_signature: {} } }
    signature = tool_result_cache_digest(normalized_args)
    signature_count = counts[:by_signature].fetch(signature, 0)
    return tool_attempt_limit_result(counts, signature_count) if counts[:total] >= MAX_TOOL_EXECUTIONS_PER_TOOL ||
                                                                 signature_count >= MAX_IDENTICAL_TOOL_EXECUTIONS

    counts[:total] += 1
    counts[:by_signature][signature] = signature_count + 1
    tool_attempt_counts[@tool.name.to_s] = counts
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
    @tool_loop_guard ||= Captain::Runtime::ToolLoopGuard.new(@context_wrapper, @tool.name)
  end

  def repeated_mutating_tool_result(normalized_args)
    entry = mutating_tool_executions[@tool.name.to_s]
    return if entry.blank? || mutation_retry_allowed?(entry, normalized_args)

    Captain::ToolResult.failure(
      error: 'This action tool already ran in the current assistant run. Do not retry it with alternate arguments.',
      retryable: false,
      audit: { failure_stage: 'tool_execution', failure_reason: 'mutation_retry_blocked' }
    )
  end

  def mutation_retry_allowed?(entry, normalized_args)
    idempotency_key = normalized_args[:idempotency_key].presence
    entry[:retryable] == true && idempotency_key.present? && entry[:idempotency_key] == idempotency_key
  end

  def track_mutating_tool_execution(normalized_args)
    return unless mutating_tool?

    mutating_tool_executions[@tool.name.to_s] = {
      idempotency_key: normalized_args[:idempotency_key].presence,
      retryable: false
    }
  end

  def record_mutating_tool_result(result)
    entry = mutating_tool_executions[@tool.name.to_s]
    return if entry.blank?

    entry[:retryable] = Captain::ToolResult.normalize(result)[:retryable] == true
  rescue StandardError
    entry[:retryable] = false
  end

  def mutating_tool_executions
    context_wrapper_context[MUTATING_TOOL_EXECUTIONS_KEY] ||= {}
  end

  def tool_result_cache_digest(normalized_args)
    Digest::SHA256.hexdigest(JSON.generate(canonical_json_value({ tool_name: @tool.name.to_s, arguments: normalized_args })))
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
    mutating_tool?
  end

  def mutating_tool?
    Llm::ToolRiskPolicy.mutating?(@tool)
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

  def check_tool_arguments!(arguments)
    Captain::ToolSafety.check_arguments!(
      feature: :assistant,
      arguments: arguments,
      preferences: captain_runtime_preferences
    )
  end

  def check_tool_results!(result)
    Captain::ToolSafety.check_result!(
      feature: :assistant,
      result: result,
      preferences: captain_runtime_preferences
    )
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
