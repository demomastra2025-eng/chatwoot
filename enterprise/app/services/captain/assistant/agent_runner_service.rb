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

  def initialize(assistant:, conversation: nil, callbacks: {}, source: nil)
    @assistant = assistant
    @conversation = conversation
    @callbacks = callbacks
    @source = source
  end

  def generate_response(message_history: [])
    Llm::Config.initialize!

    message_to_process, context = run_payload(message_history)
    Llm::EventBus.with_context(request_event_context(context)) do
      input_moderation_response = moderate_input(message_to_process, context)
      return input_moderation_response if input_moderation_response

      result = runner.run(
        message_to_process,
        context: context,
        max_turns: MAX_RUNTIME_TURNS,
        runtime_options: {
          llm_context: llm_context_for_run
        }
      )

      process_agent_result(result)
    end
  rescue StandardError => e
    # In rake/local runs, conversation may not be present, so account is optional here.
    ChatwootExceptionTracker.new(e, account: @conversation&.account).capture_exception
    Rails.logger.error "[Captain V2] AgentRunnerService error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    error_response(e)
  end

  private

  def process_agent_result(result)
    Rails.logger.info "[Captain V2] Agent result: #{result.inspect}"
    return provider_error_response(result.error) if result.respond_to?(:error) && result.error.present?

    if result.context&.dig(:pending_human_handoff).present?
      return human_handoff_response(result.context[:pending_human_handoff],
                                    result.context[:current_agent])
    end

    output = result.output
    response = output.is_a?(Hash) ? output.with_indifferent_access : { 'response' => output.to_s, 'reasoning' => 'Processed by agent' }
    response['agent_name'] = result.context&.dig(:current_agent)
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

  def provider_error_response(error)
    {
      'response' => PROVIDER_ERROR_RESPONSE,
      'reasoning' => "Provider error occurred: #{error.message}",
      'error_class' => error.class.name,
      'error_message' => error.message
    }
  end

  def build_state
    state = {
      account_id: @assistant.account_id,
      assistant_id: @assistant.id,
      assistant_config: @assistant.config,
      captain_runtime: @assistant.account.captain_preferences[:runtime]
    }
    state[:source] = @source if @source.present?

    build_conversation_state(state) if @conversation
    state[:prompt_context] = @assistant.prompt_context_state(state)
    state
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
      channel_type: @conversation.inbox&.channel_type
    }
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
    return runner unless ChatwootApp.otel_enabled?

    handoff_tool_name = Captain::Tools::HandoffTool.new(@assistant).name

    runner.on_tool_complete do |tool_name, _tool_result, context_wrapper|
      track_handoff_usage(tool_name, handoff_tool_name, context_wrapper)
    end

    runner.on_run_complete do |_agent_name, _result, context_wrapper|
      write_credits_used_metadata(context_wrapper)
    end
    runner
  end

  def track_handoff_usage(tool_name, handoff_tool_name, context_wrapper)
    return unless context_wrapper&.context
    return unless tool_name.to_s == handoff_tool_name

    context_wrapper.context[:captain_v2_handoff_tool_called] = true
  end

  def write_credits_used_metadata(context_wrapper)
    root_span = context_wrapper&.context&.dig(:__otel_tracing, :root_span)
    return unless root_span

    credit_used = !context_wrapper.context[:captain_v2_handoff_tool_called]
    root_span.set_attribute(format(ATTR_LANGFUSE_METADATA, 'credit_used'), credit_used.to_s)
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
      preferences: runtime_preferences
    )
  end

  def blocked_by_moderation_response(reason)
    {
      'response' => 'conversation_handoff',
      'reasoning' => reason
    }
  end

  def human_handoff_response(handoff_payload, agent_name)
    reason = handoff_payload[:reason].presence || handoff_payload['reason'].presence
    message = handoff_payload[:message].presence || handoff_payload['message'].presence

    {
      'response' => 'conversation_handoff',
      'reasoning' => reason.present? ? "Human handoff requested: #{reason}" : 'Human handoff requested',
      'handoff_reason' => reason,
      'handoff_message' => message,
      'agent_name' => agent_name
    }.compact
  end
end
