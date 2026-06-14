# frozen_string_literal: true

require 'digest'

class Captain::Runtime::ToolWrapper
  TOOL_NOT_BOUND_ERROR = 'Tool is not available for the current agent runtime'
  PARALLEL_MUTATING_TOOL_ERROR = 'Only one action tool can run per assistant tool-call batch'
  TOOL_RESULT_CACHE_KEY = :captain_v2_tool_result_cache

  def initialize(tool, context_wrapper)
    @tool = tool
    @context_wrapper = context_wrapper
    @name = tool.name
    @description = tool.description
    @params = tool.class.params if tool.class.respond_to?(:params)
  end

  def call(args)
    tool_context = Captain::Runtime::ToolContext.new(run_context: @context_wrapper)
    normalized_args = normalize_args(args)

    @context_wrapper.callback_manager.emit_tool_start(@tool.name, normalized_args, @context_wrapper)

    pre_execution_error = pre_execution_error(normalized_args)
    return complete_and_render(pre_execution_error) if pre_execution_error

    remember_mutating_tool_call(normalized_args)
    cached_result = cached_mutating_tool_result(normalized_args)
    return complete_and_render(cached_result) if cached_result

    result = @tool.execute(tool_context, **normalized_args)
    result_error = tool_safety_error_for(:tool_results, safety_checked_result(result))
    final_result = result_error || result
    cache_successful_mutating_tool_result(normalized_args, final_result)
    @context_wrapper.callback_manager.emit_tool_complete(@tool.name, final_result, @context_wrapper)
    return final_result if halt_result?(final_result)

    Captain::ToolResult.render(final_result)
  rescue StandardError => e
    @context_wrapper.callback_manager.emit_tool_complete(
      @tool.name,
      Captain::ToolResult.failure(error: e),
      @context_wrapper
    )
    raise
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
    @tool.respond_to?(:params_schema) ? @tool.params_schema : nil
  end

  def provider_params
    @tool.respond_to?(:provider_params) ? @tool.provider_params : {}
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

  def normalize_args(args)
    return {} if args.nil?

    raw_args = args.respond_to?(:to_h) ? args.to_h : {}
    normalized = raw_args.deep_symbolize_keys
    normalized = normalized[:parameters].deep_symbolize_keys if tool_call_envelope?(normalized)

    unwrap_nested_tool_call_envelopes(normalized)
  rescue StandardError
    {}
  end

  def tool_call_envelope?(args)
    args[:name].present? && args[:parameters].is_a?(Hash)
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

  def pre_execution_error(normalized_args)
    bound_tool_error_for_current_agent ||
      parallel_mutating_tool_error ||
      tool_safety_error_for(:tool_arguments, normalized_args)
  end

  def complete_and_render(result)
    @context_wrapper.callback_manager.emit_tool_complete(@tool.name, result, @context_wrapper)
    Captain::ToolResult.render(result)
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

  def tool_result_cache
    context_wrapper_context[TOOL_RESULT_CACHE_KEY] ||= {}
  end

  def tool_result_cache_digest(normalized_args)
    Digest::SHA256.hexdigest(JSON.generate(canonical_json_value({ tool_name: @tool.name.to_s, arguments: normalized_args })))
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
        existing_tool_calls: mutating_tool_calls_for_current_batch.map { |entry| entry[:tool_name] }
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
