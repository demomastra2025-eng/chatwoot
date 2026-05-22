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
    Llm::Config.initialize!

    message_to_process, context = run_payload(message_history)
    Llm::EventBus.with_context(request_event_context(context)) do
      input_moderation_response = moderate_input(message_to_process, context)
      return input_moderation_response if input_moderation_response

      run_agent_with_blank_response_retries(message_to_process, context)
    end
  rescue StandardError => e
    # In rake/local runs, conversation may not be present, so account is optional here.
    ChatwootExceptionTracker.new(e, account: @conversation&.account).capture_exception
    Rails.logger.error "[Captain V2] AgentRunnerService error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    error_response(e)
  end

  private

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
    end
  end

  def retry_annotated_response(response, blank_response_retried)
    return response unless blank_response_retried

    response.merge('blank_response_retry' => true)
  end

  def run_agent(message_to_process, context)
    runner.run(
      message_to_process,
      context: context,
      max_turns: MAX_RUNTIME_TURNS,
      runtime_options: {
        llm_context: llm_context_for_run,
        account: @assistant.account
      }
    )
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
  end

  def process_agent_result(result)
    Rails.logger.info "[Captain V2] Agent result: #{result.inspect}"
    handoff_tool_called = handoff_tool_called_from_context(result.context)
    return provider_error_response(result.error, handoff_tool_called: handoff_tool_called) if result.respond_to?(:error) && result.error.present?

    if result.context&.dig(:pending_response_cancellation).present?
      return response_cancellation_response(result.context[:pending_response_cancellation], result.context[:current_agent])
    end

    if result.context&.dig(:pending_human_handoff).present?
      return human_handoff_response(result.context[:pending_human_handoff],
                                    result.context[:current_agent],
                                    handoff_tool_called: handoff_tool_called)
    end

    output = result.output
    response = output.is_a?(Hash) ? output.with_indifferent_access : { 'response' => output.to_s, 'reasoning' => 'Processed by agent' }
    response['agent_name'] = result.context&.dig(:current_agent)
    response['handoff_tool_called'] = handoff_tool_called
    semantic_error = semantic_output_error(response, result.context)
    return semantic_output_error_response(semantic_error, response, result.context, handoff_tool_called: handoff_tool_called) if semantic_error

    return provider_error_response(blank_response_error, handoff_tool_called: handoff_tool_called) if blank_public_response?(response)

    moderate_output!(response, result.context&.dig(:state, :captain_runtime))
    response
  rescue Llm::SafetyPolicy::UnsafeContentError
    blocked_by_moderation_response('Agent output blocked by moderation policy')
  rescue Llm::SafetyPolicy::UnavailableError
    blocked_by_moderation_response('Agent output blocked because moderation policy is unavailable')
  end

  def error_response(error)
    message = error.respond_to?(:message) ? error.message : error.to_s

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

  def semantic_output_error_response(error, response, context, handoff_tool_called: false)
    publish_semantic_invalid_event(error, response, context)
    provider_error_response(error, handoff_tool_called: handoff_tool_called)
  end

  def semantic_output_error(response, context)
    return reserved_runtime_action_error(response) if reserved_runtime_action?(response)
    return provider_error_literal_error if provider_error_literal?(response)
    return artifact_ids_without_tool_error if artifact_ids_without_completed_tool?(response, context)

    nil
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

  def artifact_ids_without_completed_tool?(response, context)
    response_artifact_ids(response).present? && completed_tool_names(context).blank?
  end

  def artifact_ids_without_tool_error
    SemanticOutputError.new(
      'artifact_ids_without_tool',
      'Model output referenced artifact_ids without a completed tool result'
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
    Array(context&.dig(:captain_v2_completed_tool_names)).filter_map { |tool_name| tool_name.to_s.strip.presence }
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
      captain_runtime: @assistant.account.captain_preferences[:runtime]
    }
    state[:source] = @source if @source.present?
    state[:runtime_clock] = runtime_clock_state

    build_conversation_state(state) if @conversation
    state[:prompt_context] = @assistant.prompt_context_state(state)
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
    scenario_agents = @assistant.scenarios.enabled.map(&:agent)

    assistant_agent.register_handoffs(*scenario_agents) if scenario_agents.any?
    scenario_agents.each do |scenario_agent|
      sibling_agents = scenario_agents.reject { |agent| agent.equal?(scenario_agent) }
      scenario_agent.register_handoffs(assistant_agent, *sibling_agents)
    end

    [assistant_agent] + scenario_agents
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
    runner.on_tool_complete do |tool_name, _tool_result, context_wrapper|
      track_completed_tool_usage(tool_name, context_wrapper)
      track_handoff_usage(tool_name, handoff_tool_name, context_wrapper)
    end

    if ChatwootApp.otel_enabled?
      runner.on_run_complete do |_agent_name, _result, context_wrapper|
        write_credits_used_metadata(context_wrapper)
      end
    end
    runner
  end

  def track_completed_tool_usage(tool_name, context_wrapper)
    return unless context_wrapper&.context

    context_wrapper.context[:captain_v2_completed_tool_names] ||= []
    context_wrapper.context[:captain_v2_completed_tool_names] << tool_name.to_s
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
      configured_runner = Captain::Runtime::Runner.with_agents(*build_and_wire_agents)
      configured_runner = add_usage_metadata_callback(configured_runner)
      configured_runner = add_callbacks_to_runner(configured_runner) if @callbacks.any?
      install_instrumentation(configured_runner)
      configured_runner
    end
  end

  def run_payload(message_history)
    message_to_process = extract_last_user_message(message_history)
    context = build_context(message_history_without_last_user_message(message_history))
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
    message = handoff_payload[:message].presence || handoff_payload['message'].presence

    response = {
      'response' => 'conversation_handoff',
      'reasoning' => reason.present? ? "Human handoff requested: #{reason}" : 'Human handoff requested',
      'handoff_reason' => reason,
      'handoff_message' => message,
      'agent_name' => agent_name
    }
    response['handoff_tool_called'] = true if handoff_tool_called
    response.compact
  end
end
