require 'digest'
require 'securerandom'

class Captain::Assistant::AgentRunnerService
  include Integrations::LlmInstrumentationConstants
  include Captain::Assistant::LlmContextHelper
  include Captain::Assistant::RunPayloadHelper
  include Captain::Assistant::RunnerCallbacksHelper
  include Captain::Assistant::TracePayloadHelper

  PROVIDER_ERROR_RESPONSE = 'conversation_handoff_due_to_provider_error'.freeze
  CONTACT_INBOX_STATE_ATTRIBUTES = %i[id hmac_verified].freeze
  CAMPAIGN_STATE_ATTRIBUTES = %i[id title message campaign_type description].freeze
  MAX_RUNTIME_TURNS = 24
  MAX_BLANK_RESPONSE_RETRIES = 1
  MAX_FINALIZATION_ONLY_RETRIES = 1
  MAX_TOOL_ARTIFACT_SCAN_BYTES = 100_000
  MAX_COMPLETED_TOOL_RESULT_RECORDS = 50
  MCP_TOOL_ID_PREFIX = 'mcp__'.freeze
  TOOL_RESULT_FALLBACK_REASONING = [
    'Final assistant response failed after completed tool actions; ',
    'a deterministic tool-result fallback was used.'
  ].join.freeze
  ZERO_COMPLETION_BLANK_RETRY = 'blank_response_retry'.freeze
  ZERO_COMPLETION_FINALIZATION_RETRY = 'finalization_only_retry'.freeze
  ZERO_COMPLETION_TOOL_RESULT_FALLBACK = 'tool_result_fallback'.freeze

  class BlankResponseError < StandardError; end

  class SemanticOutputError < StandardError
    attr_reader :code

    def initialize(code, message)
      @code = code
      super(message)
    end
  end

  def initialize(assistant:, conversation: nil, callbacks: {}, source: nil)
    @assistant = assistant
    @conversation = conversation
    @callbacks = callbacks
    @source = source
    @handoff_tool_called = false
  end

  def generate_response(message_history: [])
    Captain::Mcp::ToolCatalog.with_runtime_cache do
      with_mcp_discovery_policy do
        Llm::Config.with_runtime_cache do
          with_llm_catalog_snapshots do
            generate_response_with_runtime_cache(message_history)
          end
        end
      end
    end
  rescue StandardError => e
    # In rake/local runs, conversation may not be present, so account is optional here.
    ChatwootExceptionTracker.new(e, account: @conversation&.account).capture_exception
    Rails.logger.error "[Captain V2] AgentRunnerService error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    error_response(e)
  end

  private

  def with_mcp_discovery_policy(&)
    return yield if mcp_discovery_required?

    Captain::Mcp::ToolCatalog.without_discovery(&)
  end

  def mcp_discovery_required?
    mcp_tool_reference?(
      [
        @assistant.config,
        @assistant.description,
        @assistant.response_guidelines,
        @assistant.guardrails,
        enabled_scenarios.map { |scenario| [scenario.tools, scenario.instruction] }
      ]
    )
  end

  def mcp_tool_reference?(value)
    case value
    when Hash
      value.any? { |key, child_value| mcp_tool_reference?(key) || mcp_tool_reference?(child_value) }
    when Array
      value.any? { |child_value| mcp_tool_reference?(child_value) }
    else
      value.to_s.include?(MCP_TOOL_ID_PREFIX)
    end
  end

  def with_llm_catalog_snapshots(&)
    Llm::OpenRouterModelCatalog.with_model_configs_snapshot do
      Llm::OpenRouterEndpointCatalog.with_endpoint_configs_snapshot(&)
    end
  end

  def generate_response_with_runtime_cache(message_history)
    time_phase('config.initialize') { Llm::Config.initialize! }

    message_to_process, context = time_phase('run_payload') { run_payload(message_history) }
    Llm::EventBus.with_context(request_event_context(context)) do
      input_moderation_response = time_phase('moderate_input') { moderate_input(message_to_process, context) }
      return input_moderation_response if input_moderation_response

      time_phase('run_agent_with_retries') { run_agent_with_blank_response_retries(message_to_process, context) }
    end
  end

  def run_agent_with_blank_response_retries(message_to_process, context)
    attempts = 0
    blank_response_retried = false
    retry_context = context

    loop do
      result = run_agent(message_to_process, retry_context)
      response = process_agent_result(result)
      return retry_annotated_response(response, blank_response_retried) unless retry_blank_response?(response, result, attempts)

      attempts += 1
      blank_response_retried = true
      retry_context = context_for_blank_response_retry(result.context, retry_context)
      publish_blank_response_retry(result, attempts)
    end
  end

  def context_for_blank_response_retry(context, fallback_context)
    source_context = context.presence || fallback_context
    source_context.deep_dup.tap do |retry_context|
      retry_context.delete(:captain_v2_handoff_tool_called)
      retry_context.delete(:captain_v2_completed_tool_names)
      retry_context.delete(:captain_v2_completed_tool_results)
    end
  end

  def retry_annotated_response(response, blank_response_retried)
    return response unless blank_response_retried

    response.merge(
      'blank_response_retry' => true,
      'zero_completion_recovered' => true,
      'zero_completion_recovery_kind' => ZERO_COMPLETION_BLANK_RETRY
    )
  end

  def run_agent(message_to_process, context, runtime_options: {})
    time_phase('runner.run') do
      runner.run(
        message_to_process,
        context: context,
        max_turns: MAX_RUNTIME_TURNS,
        runtime_options: {
          llm_context: llm_context_for_run,
          account: @assistant.account
        }.merge(runtime_options)
      )
    end
  end

  def retry_blank_response?(response, result, attempts)
    return false unless blank_response_error_payload?(response)
    return false unless attempts < MAX_BLANK_RESPONSE_RETRIES

    retry_safe_completed_tools?(result.context)
  end

  def blank_response_error_payload?(response)
    response['error_class'] == BlankResponseError.name && response['error_message'] == blank_response_error.message
  end

  def retry_safe_completed_tools?(context)
    completed_tool_names = Array(context&.dig(:captain_v2_completed_tool_names)).map(&:to_s)
    completed_tool_names.all? { |tool_name| handoff_tool_name?(tool_name) }
  end

  def handoff_tool_name?(tool_name)
    tool_name.start_with?(Captain::HandoffNaming::TOOL_PREFIX)
  end

  def publish_blank_response_retry(result, attempt)
    current_agent = result.context&.dig(:current_agent)
    Rails.logger.warn(
      "[Captain V2] Retrying blank assistant response for assistant=#{@assistant.id} " \
      "conversation=#{@conversation&.id} agent=#{current_agent} attempt=#{attempt}"
    )
    Llm::EventBus.publish(
      'run.retry',
      current_agent: current_agent,
      status: 'retrying',
      reason: 'blank_response',
      error: true,
      attempt: attempt,
      max_attempts: MAX_BLANK_RESPONSE_RETRIES
    )
    publish_zero_completion_event(
      'retry',
      blank_response_error,
      result.context,
      status: 'retrying',
      recovery_kind: ZERO_COMPLETION_BLANK_RETRY,
      attempt: attempt,
      max_attempts: MAX_BLANK_RESPONSE_RETRIES
    )
  end

  def process_agent_result(result)
    log_agent_result(result)
    handoff_tool_called = handoff_tool_called_from_context(result.context)
    if result.respond_to?(:error) && result.error.present?
      return final_error_response(result.error, result.context, handoff_tool_called: handoff_tool_called)
    end

    if result.context&.dig(:pending_response_cancellation).present?
      return response_cancellation_response(result.context[:pending_response_cancellation], result.context[:current_agent])
    end

    if result.context&.dig(:pending_human_handoff).present?
      return human_handoff_response(result.context[:pending_human_handoff],
                                    result.context[:current_agent],
                                    handoff_tool_called: handoff_tool_called)
    end

    output = result.output
    response = output.is_a?(Hash) ? output.with_indifferent_access : { 'response' => output.to_s, 'reasoning' => '' }
    response['agent_name'] = result.context&.dig(:current_agent)
    response['handoff_tool_called'] = handoff_tool_called
    sanitize_response_artifact_ids!(response, result.context)
    semantic_error = semantic_output_error(response)
    return semantic_output_error_response(semantic_error, response, result.context, handoff_tool_called: handoff_tool_called) if semantic_error

    if blank_public_response?(response)
      error = blank_response_error
      return final_error_response(error, result.context, handoff_tool_called: handoff_tool_called)
    end

    publish_tool_omission_event(response, result.context)
    moderate_output!(response, result.context&.dig(:state, :captain_runtime))
    response
  rescue Llm::SafetyPolicy::UnsafeContentError
    blocked_by_moderation_response('Agent output blocked by moderation policy')
  rescue Llm::SafetyPolicy::UnavailableError
    blocked_by_moderation_response('Agent output blocked because moderation policy is unavailable')
  end

  def log_agent_result(result)
    error = result.respond_to?(:error) ? result.error : nil
    Rails.logger.info(
      "[Captain V2] Agent result assistant_id=#{@assistant.id} conversation_id=#{@conversation&.id} " \
      "current_agent=#{result.context&.dig(:current_agent)} output_type=#{result.output.class.name} error_class=#{error&.class&.name}"
    )
  end

  def publish_tool_omission_event(response, context)
    bound_tool_ids = Array(context&.dig(:captain_v2_bound_tool_ids)).map(&:to_s).reject(&:blank?).uniq
    bound_tool_ids.reject! { |tool_id| tool_id.start_with?(Captain::HandoffNaming::TOOL_PREFIX) }
    return if bound_tool_ids.blank? || completed_tool_names(context).any?

    reasoning = response['reasoning'].to_s.squish
    Llm::EventBus.publish(
      'tool.omitted',
      feature: 'assistant',
      runtime_mode: 'captain_runtime',
      current_agent: context&.dig(:current_agent),
      reason: 'model_returned_final_response_without_tool_call',
      available_tool_count: bound_tool_ids.size,
      model_reasoning_present: reasoning.present?,
      model_reasoning_sha256: reasoning.present? ? Digest::SHA256.hexdigest(reasoning) : nil
    )
  end

  def message_role(message)
    (message[:role] || message['role']).to_s
  end

  def error_response(error)
    message = error.respond_to?(:message) ? error.message : error.to_s
    fallback_response = deterministic_tool_result_fallback_response(error, @last_tool_result_context, handoff_tool_called: false)
    return fallback_response if fallback_response

    {
      'response' => PROVIDER_ERROR_RESPONSE,
      'reasoning' => "Error occurred: #{message}",
      'error_class' => error.class.name,
      'error_message' => message
    }
  end

  def provider_error_response(error, handoff_tool_called: false)
    response = {
      'response' => PROVIDER_ERROR_RESPONSE,
      'reasoning' => "Provider error occurred: #{error.message}",
      'error_class' => error.class.name,
      'error_message' => error.message
    }
    response['handoff_tool_called'] = true if handoff_tool_called
    response
  end

  def final_error_response(error, context, handoff_tool_called: false)
    publish_zero_completion_detected_event(error, context)

    finalization_response = finalization_only_retry_response(error, context, handoff_tool_called: handoff_tool_called)
    return finalization_response if finalization_response

    deterministic_tool_result_fallback_response(error, context, handoff_tool_called: handoff_tool_called) ||
      provider_error_response(error, handoff_tool_called: handoff_tool_called)
  end

  def finalization_only_retry_response(error, context, handoff_tool_called: false)
    return if @finalization_only_retry_in_progress
    return unless finalization_only_retry_eligible?(context)

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    publish_finalization_only_retry_event(error, context, status: 'retrying')
    @finalization_only_retry_in_progress = true
    response = process_agent_result(run_finalization_only_retry(context, error))
    annotate_finalization_retry_response(response, handoff_tool_called: handoff_tool_called).tap do |annotated_response|
      next unless finalization_retry_recovered?(annotated_response)

      annotated_response['zero_completion_recovered'] = true
      annotated_response['zero_completion_recovery_kind'] = ZERO_COMPLETION_FINALIZATION_RETRY
      publish_zero_completion_event(
        'recovered',
        error,
        context,
        status: 'recovered',
        recovery_kind: ZERO_COMPLETION_FINALIZATION_RETRY,
        duration_ms: elapsed_ms(started_at)
      )
    end
  rescue StandardError => e
    Rails.logger.warn(
      "[Captain V2] Finalization-only retry failed for assistant=#{@assistant.id} " \
      "conversation=#{@conversation&.id}: #{e.class.name}: #{e.message}"
    )
    publish_finalization_only_retry_event(error, context, status: 'failed', retry_error: e, duration_ms: elapsed_ms(started_at))
    nil
  ensure
    @finalization_only_retry_in_progress = false
  end

  def run_finalization_only_retry(context, error)
    run_agent(
      nil,
      context_for_finalization_only_retry(context, error),
      runtime_options: { finalization_only: true, continue_from_history: true }
    )
  end

  def annotate_finalization_retry_response(response, handoff_tool_called: false)
    response['handoff_tool_called'] = true if handoff_tool_called
    response['finalization_only_retry'] = true
    response
  end

  def finalization_retry_recovered?(response)
    response['response'].present? &&
      response['response'] != PROVIDER_ERROR_RESPONSE &&
      response['error_class'].blank? &&
      response['tool_result_fallback'].blank?
  end

  def finalization_only_retry_eligible?(context)
    return false if context.blank?
    return false if finalization_only_retry_attempted?(context)
    return false if successful_non_handoff_tool_records(context).blank? && !terminal_tool_stop?(context)

    conversation_history_has_tool_results?(context)
  end

  def terminal_tool_stop?(context)
    context_value(context, Captain::Runtime::ToolWrapper::TERMINAL_TOOL_STOP_KEY).present?
  end

  def finalization_only_retry_attempted?(context)
    context_value(context, :captain_v2_finalization_only_retry).present?
  end

  def conversation_history_has_tool_results?(context)
    Array(context_value(context, :conversation_history)).any? do |message|
      message_role(message) == 'tool' && (message[:content] || message['content']).present?
    end
  end

  def context_for_finalization_only_retry(context, error)
    context.deep_dup.tap do |retry_context|
      retry_context[:captain_v2_finalization_only_retry] = {
        error_class: error.class.name,
        error_message: error.message,
        max_attempts: MAX_FINALIZATION_ONLY_RETRIES
      }
    end
  rescue StandardError
    context.merge(
      captain_v2_finalization_only_retry: {
        error_class: error.class.name,
        error_message: error.message,
        max_attempts: MAX_FINALIZATION_ONLY_RETRIES
      }
    )
  end

  def publish_finalization_only_retry_event(error, context, status:, retry_error: nil, duration_ms: nil)
    records = successful_non_handoff_tool_records(context)
    Llm::EventBus.publish(
      'schema.finalization_retry',
      schema_name: Captain::ResponseSchema.name,
      current_agent: context_value(context, :current_agent),
      status: status,
      reason: error.message,
      error_class: error.class.name,
      retry_error_class: retry_error&.class&.name,
      retry_error_message: retry_error&.message,
      duration_ms: duration_ms,
      completed_tools_count: records.size,
      completed_tool_names: tool_result_counts(records).keys
    )
    publish_zero_completion_event(
      status == 'failed' ? 'failed' : 'retry',
      error,
      context,
      status: status,
      recovery_kind: ZERO_COMPLETION_FINALIZATION_RETRY,
      retry_error_class: retry_error&.class&.name,
      retry_error_message: retry_error&.message,
      duration_ms: duration_ms
    )
  end

  def elapsed_ms(started_at)
    return if started_at.blank?

    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
  end

  def context_value(context, key)
    return unless context.respond_to?(:[])

    context[key] || context[key.to_s]
  end

  def deterministic_tool_result_fallback_response(error, context, handoff_tool_called: false)
    successful_records = successful_non_handoff_tool_records(context)
    return if successful_records.blank?

    publish_tool_result_fallback_event(error, context, successful_records)

    {
      'response' => tool_result_fallback_message(successful_records),
      'reasoning' => TOOL_RESULT_FALLBACK_REASONING,
      'system_fallback_reason' => TOOL_RESULT_FALLBACK_REASONING,
      'agent_name' => context&.dig(:current_agent),
      'handoff_tool_called' => handoff_tool_called,
      'schema_fallback' => true,
      'tool_result_fallback' => true,
      'zero_completion_recovered' => true,
      'zero_completion_recovery_kind' => ZERO_COMPLETION_TOOL_RESULT_FALLBACK,
      'error_class' => error.class.name,
      'error_message' => error.message
    }
  end

  def publish_tool_result_fallback_event(error, context, records)
    Llm::EventBus.publish(
      'schema.fallback',
      schema_name: Captain::ResponseSchema.name,
      current_agent: context&.dig(:current_agent),
      status: 'fallback',
      reason: error.message,
      error_class: error.class.name,
      completed_tools_count: records.size,
      completed_tool_names: tool_result_counts(records).keys,
      fallback_kind: 'completed_tool_result_summary'
    )
    publish_zero_completion_event(
      'recovered',
      error,
      context,
      status: 'recovered',
      recovery_kind: ZERO_COMPLETION_TOOL_RESULT_FALLBACK,
      fallback_kind: 'completed_tool_result_summary'
    )
  end

  def publish_zero_completion_detected_event(error, context)
    return unless zero_completion_error?(error, context)

    publish_zero_completion_event('detected', error, context, status: 'detected')
  end

  def zero_completion_error?(error, context)
    error.is_a?(BlankResponseError) || successful_non_handoff_tool_records(context).present?
  end

  def publish_zero_completion_event(event, error, context, status:, recovery_kind: nil, **extra_payload)
    records = successful_non_handoff_tool_records(context)
    Llm::EventBus.publish(
      "zero_completion.#{event}",
      {
        schema_name: Captain::ResponseSchema.name,
        current_agent: context_value(context, :current_agent),
        status: status,
        reason: error.message,
        error_class: error.class.name,
        recovery_kind: recovery_kind,
        completed_tools_count: records.size,
        completed_tool_names: tool_result_counts(records).keys
      }.merge(extra_payload).compact
    )
  end

  def semantic_output_error_response(error, response, context, handoff_tool_called: false)
    publish_semantic_invalid_event(error, response, context)
    final_error_response(error, context, handoff_tool_called: handoff_tool_called)
  end

  def semantic_output_error(response)
    return invalid_public_response_error(response) if invalid_public_response?(response)
    return reserved_runtime_action_error(response) if reserved_runtime_action?(response)
    return provider_error_literal_error if provider_error_literal?(response)
    return invalid_handoff_output_error if invalid_handoff_output?(response)

    nil
  end

  def invalid_public_response?(response)
    return false unless response.key?('response')

    Llm::CaptainResponseContentNormalizer.invalid_public_response?(response['response'])
  end

  def invalid_public_response_error(response)
    SemanticOutputError.new(
      'invalid_public_response',
      Llm::CaptainResponseContentNormalizer.invalid_public_response_message(response['response'])
    )
  end

  def reserved_runtime_action?(response)
    ActiveModel::Type::Boolean.new.cast(response['response_cancelled']) || response['response'].to_s == 'response_cancelled'
  end

  def reserved_runtime_action_error(response)
    action = response['response'].presence || 'response_cancelled'
    SemanticOutputError.new(
      'reserved_runtime_action',
      "Model output attempted reserved runtime action #{action}"
    )
  end

  def provider_error_literal?(response)
    response['response'].to_s == PROVIDER_ERROR_RESPONSE && response['error_class'].blank? && response['error_message'].blank?
  end

  def provider_error_literal_error
    SemanticOutputError.new(
      'reserved_runtime_action',
      "Model output attempted reserved runtime action #{PROVIDER_ERROR_RESPONSE}"
    )
  end

  def invalid_handoff_output?(response)
    response['response'].to_s == 'conversation_handoff'
  end

  def invalid_handoff_output_error
    SemanticOutputError.new(
      'invalid_handoff_output',
      'Model output attempted human handoff without runtime handoff state'
    )
  end

  def sanitize_response_artifact_ids!(response, context)
    artifact_ids = response_artifact_ids(response)
    available_ids = available_artifact_ids(context)
    return if artifact_ids.blank?

    sanitized_ids = artifact_ids & available_ids
    return if sanitized_ids == artifact_ids

    response['artifact_ids'] = sanitized_ids
    Rails.logger.warn(
      '[Captain V2] Dropped model artifact_ids not exposed by completed tool results ' \
      "assistant=#{@assistant.id} conversation=#{@conversation&.id} " \
      "requested=#{artifact_ids.size} kept=#{sanitized_ids.size} completed_tools=#{completed_tool_names(context).size}"
    )
  end

  def response_artifact_ids(response)
    raw_artifact_ids = response['artifact_ids']
    case raw_artifact_ids
    when Array
      raw_artifact_ids.filter_map { |artifact_id| artifact_id.to_s.strip.presence }
    when String
      raw_artifact_ids.to_s.split(/[,\s]+/).filter_map(&:presence)
    else
      []
    end
  end

  def completed_tool_names(context)
    Array(context&.dig(:captain_v2_completed_tool_names)).filter_map { |tool_name| tool_name.to_s.strip.presence }.uniq
  end

  def successful_non_handoff_tool_records(context)
    tool_result_records(context).select do |record|
      record[:success] && !handoff_tool_name?(record[:tool_name].to_s)
    end
  end

  def tool_result_records(context)
    records = Array(context&.dig(:captain_v2_completed_tool_results))
    return records.filter_map { |record| normalized_tool_result_record(record) } if records.present?

    completed_tool_names(context).map { |tool_name| { tool_name: tool_name, success: true } }
  end

  def normalized_tool_result_record(record)
    hash = record.respond_to?(:to_h) ? record.to_h.with_indifferent_access : {}
    tool_name = hash[:tool_name].to_s.strip.presence
    return if tool_name.blank?

    {
      tool_name: tool_name,
      success: ActiveModel::Type::Boolean.new.cast(hash[:success]),
      retryable: hash[:retryable],
      data_type: hash[:data_type],
      message_type: hash[:message_type],
      error_type: hash[:error_type]
    }.compact
  end

  def tool_result_fallback_message(records)
    "Request processed. Completed actions: #{formatted_tool_result_counts(records)}."
  end

  def formatted_tool_result_counts(records)
    tool_result_counts(records).map do |tool_name, count|
      "#{human_tool_name(tool_name)} ×#{count}"
    end.join(', ')
  end

  def tool_result_counts(records)
    records.each_with_object({}) do |record, counts|
      tool_name = record[:tool_name].to_s
      counts[tool_name] ||= 0
      counts[tool_name] += 1
    end
  end

  def human_tool_name(tool_name)
    definition = Captain::ToolRegistry.definition_for(tool_name)
    return definition.title.to_s if definition&.title.present?

    'tool action'
  rescue StandardError
    'tool action'
  end

  def available_artifact_ids(context)
    Array(context&.dig(:captain_v2_artifact_ids)).filter_map { |artifact_id| artifact_id.to_s.strip.presence }.uniq
  end

  def publish_semantic_invalid_event(error, response, context)
    artifact_ids = response_artifact_ids(response)
    Llm::EventBus.publish(
      'schema.invalid',
      schema_name: Captain::ResponseSchema.name,
      current_agent: context&.dig(:current_agent),
      reason: error.message,
      semantic_error_code: error.code,
      response_type: 'hash',
      response_size: response.to_json.bytesize,
      artifact_ids_count: artifact_ids.size,
      available_artifact_ids_count: available_artifact_ids(context).size,
      completed_tools_count: completed_tool_names(context).size
    )
  end

  def handoff_tool_called_from_context(context)
    context&.dig(:captain_v2_handoff_tool_called) || false
  end

  def blank_public_response?(response)
    return false if response['response'] == 'conversation_handoff'
    return false if response['response'] == PROVIDER_ERROR_RESPONSE

    response['response'].blank?
  end

  def blank_response_error
    BlankResponseError.new('Assistant runtime returned a blank response')
  end

  def build_state
    state = {
      account_id: @assistant.account_id,
      assistant_id: @assistant.id,
      assistant_config: @assistant.config,
      captain_runtime: @assistant.account.captain_runtime_preferences
    }
    state[:source] = @source if @source.present?
    state[:runtime_clock] = runtime_clock_state

    time_phase('build_conversation_state') { build_conversation_state(state) } if @conversation
    state[:prompt_context] = time_phase('prompt_context_state') { @assistant.prompt_context_state(state) }
    state
  end

  def runtime_clock_state
    timezone = runtime_timezone
    now = Time.current
    local_now = now.in_time_zone(timezone)

    {
      now_utc: now.utc.iso8601,
      now_local: local_now.iso8601,
      timezone: timezone,
      date_local: local_now.to_date.iso8601,
      time_local: local_now.strftime('%H:%M:%S')
    }
  end

  def runtime_timezone
    configured_timezone = @conversation&.inbox&.timezone.presence || Time.zone.name
    return configured_timezone if Time.find_zone(configured_timezone).present?

    'UTC'
  rescue StandardError
    'UTC'
  end

  def request_event_context(context)
    state = context[:state] || {}
    conversation = state[:conversation] || {}

    {
      request_id: SecureRandom.uuid,
      feature: 'assistant',
      runtime_mode: 'captain_runtime',
      account_id: state[:account_id],
      assistant_id: state[:assistant_id],
      conversation_id: conversation[:id],
      conversation_display_id: conversation[:display_id],
      channel_type: state[:channel_type],
      source: state[:source],
      session_id: context[:session_id]
    }.compact
  end

  def build_conversation_state(state)
    state.merge!(base_conversation_state)
    state[:contact] = slice_attrs(@conversation.contact, Captain::ContextFields::CONTACT_STATE_ATTRIBUTES) if @conversation.contact
    add_related_record_state(state)
    state.compact!
  end

  def base_conversation_state
    {
      conversation: slice_attrs(@conversation, Captain::ContextFields::CONVERSATION_STATE_ATTRIBUTES),
      channel_type: @conversation.inbox&.channel_type,
      reply_window: reply_window_state
    }
  end

  def reply_window_state
    return {} unless @conversation&.inbox&.channel.is_a?(Channel::Whatsapp)

    last_incoming_at = @conversation.messages
                                    .where(account_id: @conversation.account_id)
                                    .incoming
                                    .reorder(created_at: :desc)
                                    .limit(1)
                                    .pick(:created_at)
    closes_at = last_incoming_at&.+(Conversations::MessageWindowService::MESSAGING_WINDOW_24_HOURS)

    {
      channel: 'official_whatsapp',
      last_incoming_at: last_incoming_at&.iso8601,
      closes_at: closes_at&.iso8601,
      open_now: closes_at.present? && Time.current < closes_at,
      requires_template_after_close: true
    }.compact
  end

  def add_related_record_state(state)
    state[:communication_thread] = Captain::ContextFields.communication_thread_state_for(
      account: @assistant.account,
      conversation: @conversation,
      assistant: @assistant
    )
    state[:deal] = Captain::ContextFields.deal_state_for(account: @assistant.account, conversation: @conversation)
    state[:task] = Captain::ContextFields.task_state_for(account: @assistant.account, conversation: @conversation)
    state[:appointment] = Captain::ContextFields.appointment_state_for(account: @assistant.account, conversation: @conversation)
    state[:campaign] = slice_attrs(@conversation.campaign, CAMPAIGN_STATE_ATTRIBUTES) if @conversation.campaign
    state[:contact_inbox] = slice_attrs(@conversation.contact_inbox, CONTACT_INBOX_STATE_ATTRIBUTES) if @conversation.contact_inbox
  end

  def slice_attrs(record, keys)
    record.attributes.symbolize_keys.slice(*keys)
  end

  def build_and_wire_agents
    assistant_agent = @assistant.agent
    scenario_agents = enabled_scenarios.map(&:agent)

    assistant_agent.register_handoffs(*scenario_agents) if scenario_agents.any?
    scenario_agents.each do |scenario_agent|
      sibling_agents = scenario_agents.reject { |agent| agent.equal?(scenario_agent) }
      scenario_agent.register_handoffs(assistant_agent, *sibling_agents)
    end

    [assistant_agent] + scenario_agents
  end

  def enabled_scenarios
    @enabled_scenarios ||= @assistant.scenarios.enabled.to_a
  end

  def install_instrumentation(runner)
    if ChatwootApp.otel_enabled?
      Captain::Runtime::Instrumentation.install(
        runner,
        tracer: OpentelemetryConfig.tracer,
        trace_name: 'llm.captain_v2',
        span_attributes: {
          ATTR_LANGFUSE_TAGS => ['captain_v2'].to_json
        },
        attribute_provider: ->(context_wrapper) { dynamic_trace_attributes(context_wrapper) }
      )
      register_trace_input_callback(runner)
    end

    Captain::Runtime::EventBusInstrumentation.install(runner)
  end

  def dynamic_trace_attributes(context_wrapper)
    state = context_wrapper&.context&.dig(:state) || {}
    conversation = state[:conversation] || {}
    preferences = state[:captain_runtime]
    trace_input = context_wrapper&.context&.dig(:captain_v2_trace_input)

    {
      ATTR_LANGFUSE_USER_ID => state[:account_id],
      format(ATTR_LANGFUSE_METADATA, 'assistant_id') => state[:assistant_id],
      format(ATTR_LANGFUSE_METADATA, 'conversation_id') => conversation[:id],
      format(ATTR_LANGFUSE_METADATA, 'conversation_display_id') => conversation[:display_id],
      format(ATTR_LANGFUSE_METADATA, 'channel_type') => state[:channel_type],
      format(ATTR_LANGFUSE_METADATA, 'source') => state[:source],
      'trace_input_capture' => Llm::TracePayloadPolicy.trace_input_capture?(preferences: preferences),
      'trace_output_capture' => Llm::TracePayloadPolicy.trace_output_capture?(preferences: preferences),
      ATTR_LANGFUSE_TRACE_INPUT => trace_input,
      ATTR_LANGFUSE_OBSERVATION_INPUT => trace_input
    }.compact.transform_values do |value|
      value.is_a?(TrueClass) || value.is_a?(FalseClass) ? value : value.to_s
    end
  end

  def add_usage_metadata_callback(runner)
    handoff_tool_name = Captain::Tools::HandoffTool.new(@assistant).name

    # This callback feeds ResponseBuilderJob and blank-response retry safety even when OTEL is disabled.
    runner.on_tool_complete do |tool_name, tool_result, context_wrapper|
      track_completed_tool_usage(tool_name, tool_result, context_wrapper)
      track_handoff_usage(tool_name, handoff_tool_name, context_wrapper)
    end

    if ChatwootApp.otel_enabled?
      runner.on_run_complete do |_agent_name, _result, context_wrapper|
        write_credits_used_metadata(context_wrapper)
      end
    end
    runner
  end

  def track_completed_tool_usage(tool_name, tool_result, context_wrapper)
    return unless context_wrapper&.context

    context_wrapper.context[:captain_v2_completed_tool_names] ||= []
    context_wrapper.context[:captain_v2_completed_tool_names] << tool_name.to_s
    track_completed_tool_result(tool_name, tool_result, context_wrapper)
    artifact_ids = extract_tool_artifact_ids(tool_result)
    if artifact_ids.present?
      context_wrapper.context[:captain_v2_artifact_ids] ||= []
      context_wrapper.context[:captain_v2_artifact_ids] |= artifact_ids
    end
    remember_last_tool_result_context(context_wrapper)
  end

  def remember_last_tool_result_context(context_wrapper)
    @last_tool_result_context = context_wrapper.context.deep_dup
  rescue StandardError
    @last_tool_result_context = context_wrapper.context
  end

  def track_completed_tool_result(tool_name, tool_result, context_wrapper)
    normalized = Captain::ToolResult.normalize(tool_result)
    context_wrapper.context[:captain_v2_completed_tool_results] ||= []
    context_wrapper.context[:captain_v2_completed_tool_results] << completed_tool_result_record(tool_name, normalized)
    context_wrapper.context[:captain_v2_completed_tool_results] =
      context_wrapper.context[:captain_v2_completed_tool_results].last(MAX_COMPLETED_TOOL_RESULT_RECORDS)
  end

  def completed_tool_result_record(tool_name, normalized_result)
    {
      tool_name: tool_name.to_s,
      success: !Captain::ToolResult.error?(normalized_result),
      retryable: normalized_result[:retryable],
      data_type: tool_payload_type(normalized_result[:data]),
      message_type: tool_payload_type(normalized_result[:message]),
      error_type: tool_payload_type(normalized_result[:error])
    }.compact
  end

  def tool_payload_type(value)
    case value
    when Hash
      'hash'
    when Array
      'array'
    when NilClass
      'nil'
    else
      value.class.name.demodulize.underscore
    end
  end

  def extract_tool_artifact_ids(tool_result)
    normalized = Captain::ToolResult.normalize(tool_result)
    artifact_ids_from_value(normalized[:data]) + artifact_ids_from_value(normalized[:message])
  rescue StandardError
    []
  end

  def artifact_ids_from_value(value)
    case value
    when Hash
      artifact_ids_from_hash(value)
    when Array
      value.flat_map { |item| artifact_ids_from_value(item) }
    when String
      artifact_ids_from_string(value)
    else
      []
    end.filter_map { |artifact_id| artifact_id.to_s.strip.presence }.uniq
  end

  def artifact_ids_from_hash(value)
    hash = value.with_indifferent_access
    artifact_ids = []
    artifact_ids << hash[:artifact_id] if hash[:artifact_id].present?
    artifact_ids.concat(Array(hash[:artifact_candidates]).filter_map do |candidate|
      next unless candidate.respond_to?(:[])

      candidate[:id] || candidate['id']
    end)
    artifact_ids.concat(hash.values.flat_map { |nested_value| artifact_ids_from_value(nested_value) })
    artifact_ids
  end

  def artifact_ids_from_string(value)
    return [] if value.bytesize > MAX_TOOL_ARTIFACT_SCAN_BYTES

    stripped = value.strip
    return [] unless stripped.start_with?('{', '[')

    artifact_ids_from_value(JSON.parse(stripped))
  rescue JSON::ParserError
    []
  end

  def track_handoff_usage(tool_name, handoff_tool_name, context_wrapper)
    return unless context_wrapper&.context
    return unless tool_name.to_s == handoff_tool_name

    context_wrapper.context[:captain_v2_handoff_tool_called] = true
    @handoff_tool_called = true
  end

  def write_credits_used_metadata(context_wrapper)
    root_span = context_wrapper&.context&.dig(:__otel_tracing, :root_span)
    return unless root_span

    root_span.set_attribute(format(ATTR_LANGFUSE_METADATA, 'credit_used'), @handoff_tool_called ? 'false' : 'true')
  end

  def runner
    @runner ||= begin
      agents = time_phase('build_and_wire_agents') { build_and_wire_agents }
      configured_runner = Captain::Runtime::Runner.with_agents(*agents)
      configured_runner = add_usage_metadata_callback(configured_runner)
      configured_runner = add_callbacks_to_runner(configured_runner) if @callbacks.any?
      time_phase('install_instrumentation') { install_instrumentation(configured_runner) }
      configured_runner
    end
  end

  def run_payload(message_history)
    message_to_process = extract_last_user_message(message_history)
    context = build_context(message_history_without_last_user_message(message_history))
    context[:captain_v2_current_input] = message_to_process
    enrich_context_with_trace_payload!(context, message_history, message_to_process)
    [message_to_process, context]
  end

  def moderate_input(message_to_process, context)
    Llm::SafetyPolicy.check!(
      feature: :assistant,
      stage: :input,
      content: message_to_process,
      account: @assistant.account,
      preferences: context.dig(:state, :captain_runtime)
    )
    nil
  rescue Llm::SafetyPolicy::UnsafeContentError
    blocked_by_moderation_response('Agent input blocked by moderation policy')
  rescue Llm::SafetyPolicy::UnavailableError
    blocked_by_moderation_response('Agent input blocked because moderation policy is unavailable')
  end

  def moderate_output!(response, runtime_preferences)
    Llm::SafetyPolicy.check!(
      feature: :assistant,
      stage: :output,
      content: response['response'],
      account: @assistant.account,
      preferences: runtime_preferences
    )
  end

  def time_phase(name)
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
  ensure
    duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
    if duration_ms >= 250
      Rails.logger.info(
        "[CAPTAIN][Timing] assistant_id=#{@assistant&.id} conversation_id=#{@conversation&.id} " \
        "phase=#{name} duration_ms=#{duration_ms}"
      )
    end
  end

  def blocked_by_moderation_response(reason)
    {
      'response' => 'conversation_handoff',
      'reasoning' => reason
    }
  end

  def response_cancellation_response(cancellation_payload, agent_name)
    reason = cancellation_payload[:reason].presence || cancellation_payload['reason'].presence

    {
      'response' => 'response_cancelled',
      'response_cancelled' => true,
      'cancel_reason' => reason,
      'agent_name' => agent_name
    }.compact
  end

  def human_handoff_response(handoff_payload, agent_name, handoff_tool_called: false)
    reason = handoff_payload[:reason].presence || handoff_payload['reason'].presence
    status_reason = handoff_payload[:status_reason].presence || handoff_payload['status_reason'].presence
    message = handoff_payload[:message].presence || handoff_payload['message'].presence

    response = {
      'response' => 'conversation_handoff',
      'reasoning' => reason.present? ? "Human handoff requested: #{reason}" : 'Human handoff requested',
      'handoff_reason' => reason,
      'handoff_status_reason' => status_reason,
      'handoff_message' => message,
      'agent_name' => agent_name
    }
    response['handoff_tool_called'] = true if handoff_tool_called
    response.compact
  end
end
