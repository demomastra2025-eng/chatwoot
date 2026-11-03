require 'digest'
require 'securerandom'

class Captain::Assistant::AgentRunnerService
  include Integrations::LlmInstrumentationConstants
  include Captain::Assistant::LlmContextHelper
  include Captain::Assistant::PatientLanguageHelper
  include Captain::Assistant::RoutingHelper
  include Captain::Assistant::RunPayloadHelper
  include Captain::Assistant::RunnerCallbacksHelper
  include Captain::Assistant::TracePayloadHelper

  PROVIDER_ERROR_RESPONSE = 'conversation_handoff_due_to_provider_error'.freeze
  PROVIDER_ERROR_AUTHORIZED_KEY = 'provider_error_handoff_authorized'.freeze
  TECHNICAL_FAILURE_ERROR_CLASS = 'Captain::TechnicalToolFailure'.freeze
  # Marks a turn the safety policy blocked (input or output) or could not check.
  # Only the runtime sets it; a model output never carries it.
  MODERATION_BLOCKED_KEY = 'moderation_blocked'.freeze
  CONTACT_INBOX_STATE_ATTRIBUTES = %i[id hmac_verified].freeze
  CAMPAIGN_STATE_ATTRIBUTES = %i[id title message campaign_type description].freeze
  MAX_RUNTIME_TURNS = 24
  MAX_SUGGESTION_RUNTIME_TURNS = 10
  RESPONSE_MODES = %w[reply suppress].freeze
  SUGGESTION_RESPONSE_MODES = (RESPONSE_MODES + %w[human]).freeze
  MAX_BLANK_RESPONSE_RETRIES = 1
  MAX_FINALIZATION_ONLY_RETRIES = 1
  MAX_TOOL_ARTIFACT_SCAN_BYTES = 100_000
  MAX_COMPLETED_TOOL_RESULT_RECORDS = 50
  APPOINTMENT_MUTATION_TOOL_NAMES = %w[create_appointment update_appointment].freeze
  APPOINTMENT_STATUS_TOOL_NAME = 'get_appointment_provider_status'.freeze
  APPOINTMENT_PROVIDER_OPERATIONS = { 'create_appointment' => 'create_reception', 'update_appointment' => 'move_reception' }.freeze
  MCP_TOOL_ID_PREFIX = 'mcp__'.freeze
  ZERO_COMPLETION_BLANK_RETRY = 'blank_response_retry'.freeze
  ZERO_COMPLETION_FINALIZATION_RETRY = 'finalization_only_retry'.freeze
  # What a reply suggestion reads at its start (see #preload_suggestion_context), as the outcome event names it.
  PRELOAD_PARTS = %i[card appointments faq].freeze

  class BlankResponseError < StandardError; end

  class SemanticOutputError < StandardError
    attr_reader :code

    def initialize(code, message)
      @code = code
      super(message)
    end
  end

  # scope: the channel the run belongs to (Captain::ChannelScope). The router picks the agent among its enabled agents; the run
  # belongs to the channel, never to an agent.
  # assistant: one agent that runs alone, with no channel, router or durable session (the writer of a touch or a campaign message, the
  # tool context of an action a manager approved). Exactly one of the two is given.
  # request_id: the id the llm events of the run share when the caller has one (a reply suggestion request).
  def initialize(scope: nil, assistant: nil, conversation: nil, callbacks: {}, source: nil, response_fence: nil, test_overrides: {},
                 playground_session: nil, deal: nil, incoming_message_id: nil, request_id: nil)
    raise ArgumentError, 'A run belongs to a channel scope or to one agent' unless scope.present? ^ assistant.present?

    @scope = scope
    @assistant = assistant
    @request_id = request_id.presence
    @conversation = conversation
    @callbacks = callbacks
    @source = source
    @event_deal = deal
    @incoming_message_id = incoming_message_id
    @playground_session = source.to_s == 'playground' ? playground_session : nil
    @conversation = @playground_session.conversation if @playground_session
    @response_fence = response_fence.to_h.symbolize_keys.compact
    @test_overrides = if source.to_s == 'playground'
                        test_overrides.to_h.symbolize_keys.slice(:model, :temperature, :thinking_effort)
                      else
                        {}
                      end
  end

  def generate_response(message_history: [])
    previous_actor = Current.executed_by
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    policy = if @playground_session
               Outbound::PlaygroundDeliveryPolicy.for_run(@playground_session.run_policy)
             else
               Outbound::PlaygroundDeliveryPolicy.policy_for(conversation: @conversation)
             end
    response = with_iin_token_vault do
      Outbound::PlaygroundDeliveryPolicy.with(policy) do
        guard_public_response(generate_response_in_runtime_cache(message_history))
      end
    end
    add_playground_latency(with_agent_identity(with_outcome_facts(response)), started_at)
  rescue Captain::Conversation::ControlGenerationStaleError
    raise
  rescue Captain::Safety::CustomRulesRuntime::HandoffRequired => e
    @acting_assistant_id = e.assistant_id
    add_playground_latency(with_agent_identity(with_outcome_facts(Captain::Safety::CustomRulesRuntime.response_for(e))), started_at)
  rescue StandardError => e
    # In rake/local runs, conversation may not be present, so account is optional here.
    ChatwootExceptionTracker.new(e, account: @conversation&.account).capture_exception
    Rails.logger.error "[Captain V2] AgentRunnerService error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    add_playground_latency(with_agent_identity(with_outcome_facts(guard_public_response(error_response(e)))), started_at)
  ensure
    Current.executed_by = previous_actor
  end

  private

  def with_outcome_facts(response)
    return response unless response.is_a?(Hash)

    response.merge('outcome_run_facts' => Captain::OutcomeFacts.from_run(@custom_guardrail_context, response))
  end

  def guard_public_response(response)
    return response unless response.is_a?(Hash) && response['response'].present?

    # The history shows each message after its send time ("[Sat 24.10 09:50] ..."); a model that copies one into its reply loses it here.
    response['response'] = Captain::PromptClock.unstamped(response['response'])
    return response if response['response_suppressed'] || response['response_cancelled']
    return response if ['conversation_handoff', PROVIDER_ERROR_RESPONSE, 'response_cancelled'].include?(response['response'])

    response['response'] = Llm::PiiSessionPseudonymizer.unmask_customer_text(response['response'])
    response['response'] = Scheduling::IinValidator.redact_customer_text(response['response'])

    checked = Captain::Safety::CustomRulesRuntime.check_output!(
      account: account, agent_id: acting_agent_id, context: @custom_guardrail_context.to_h, response: response
    )
    if checked.is_a?(Hash) && checked['response'].is_a?(String)
      checked['response'] = Llm::PiiSessionPseudonymizer.unmask_customer_text(checked['response'])
      checked['response'] = Scheduling::IinValidator.redact_customer_text(checked['response'])
    end
    checked
  rescue Captain::Safety::CustomRulesRuntime::HandoffRequired => e
    @acting_assistant_id = e.assistant_id
    Captain::Safety::CustomRulesRuntime.response_for(e)
  rescue Llm::SafetyPolicy::UnsafeContentError, Llm::SafetyPolicy::UnavailableError => e
    blocked_by_moderation_response('Revised agent output blocked by safety policy', safety_reason: e.reason)
  end

  def account
    @scope ? @scope.account : @assistant&.account
  end

  def with_iin_token_vault(&)
    scope_id = iin_vault_scope_id
    Llm::IinTokenVault.with_scope(account_id: account&.id, scope_id: scope_id) do
      Llm::PiiSessionPseudonymizer.with_scope(
        account_id: account&.id,
        scope_id: scope_id,
        conversation: @conversation,
        &
      )
    end
  end

  def iin_vault_scope_id
    return "pg:#{@playground_session.id}" if @playground_session
    return Llm::IinTokenVault.conversation_scope_id(@conversation) if @conversation
    return "deal:#{@event_deal.id}" if @event_deal

    "run:#{@request_id || object_id}"
  end

  # A run in a channel (the router picks the agent); a run of one given agent has no graph, router or session.
  def graph_run?
    @scope.present?
  end

  # The agent the answer is attributed to: the one that acted, or the agent of a run alone. nil: the AI itself (no agent holds the
  # conversation and none produced the output).
  def acting_agent_id
    @acting_assistant_id || @assistant&.id
  end

  def generate_response_in_runtime_cache(message_history)
    Captain::Mcp::ToolCatalog.with_runtime_cache do
      with_mcp_discovery_policy do
        Llm::Config.with_runtime_cache do
          with_llm_catalog_snapshots do
            generate_response_with_runtime_cache(message_history)
          end
        end
      end
    end
  end

  def with_mcp_discovery_policy(&)
    return yield if mcp_discovery_required?

    Captain::Mcp::ToolCatalog.without_discovery(&)
  end

  def mcp_discovery_required?
    return false if @source.to_s == 'playground'
    return false unless Outbound::PlaygroundDeliveryPolicy.policy_for(conversation: @conversation).nil?

    actors = graph_run? ? agent_run_context.graph.agents : [@assistant]
    mcp_tool_reference?(actors.map do |actor|
      [actor.config, actor.description, actor.response_guidelines, actor.guardrails]
    end)
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

  # One patient turn: the run state is built, the router decides who answers (in parallel with the platform safety check of the input,
  # see RoutingHelper), the custom input rules run, and the decision is applied (TurnDispatcher): one agent
  # runs, a council runs, or the conversation goes to staff without an agent call. A clinic with one agent makes no decision.
  def generate_response_with_runtime_cache(message_history)
    time_phase('config.initialize') { Llm::Config.initialize! }

    # The language of the patient is decided while the history, the run state and the agents are built (see PatientLanguageHelper);
    # the run waits for it at its first agent call.
    start_patient_language_detection
    message_to_process, context = time_phase('run_payload') { run_payload(message_history) }
    @current_patient_text = latest_patient_text(message_to_process, context)
    Llm::EventBus.with_context(request_event_context(context)) do
      start_faq_preload(message_to_process, context)
      time_phase('routing_start') { start_routing(context) }
      input_moderation_response = time_phase('moderate_input') { moderate_input(message_to_process, context) }
      if input_moderation_response
        # A blocked input has no use for the decision: the turn ends now, without waiting for the router.
        abandon_routing
        return input_moderation_response
      end

      routed_turn(message_to_process, context)
    end
  ensure
    settle_routing
    settle_patient_language_detection
  end

  def routed_turn(message_to_process, context)
    return no_agent_response(context) if nobody_can_answer?

    @turn_decision = time_phase('routing_await') { await_routing(context) }
    limit_suggestion_budget(@turn_decision)
    check_custom_input_rules!(message_to_process, context)
    # Before the patient language is decided and an agent is called: a cancelled or out-of-time suggestion stops here.
    Captain::ReplySuggestion::RunControl.checkpoint!(:moderation)
    return routed_human_response(context) if @turn_decision&.human?
    return routed_no_reply_response if no_reply_without_runner?

    time_phase('dispatch') { turn_dispatcher.prepare!(context) } if graph_run?
    # The chosen agent (or the acting agent of a council) holds the conversation now: a failure of its run answers as it.
    @acting_assistant_id = context[:acting_assistant_id] if context[:acting_assistant_id]
    time_phase('preload') { preload_suggestion_context(context) }
    time_phase('run_agent_with_retries') { run_agent_with_blank_response_retries(message_to_process, context) }
  rescue Captain::Runtime::DecisionRouter::UnavailableError => e
    routing_failure_response(e, context)
  rescue Captain::Runtime::TurnDispatcher::CouncilUnavailable => e
    council_unavailable_response(e, context)
  end

  # Every agent of the channel is off, or several are on and none has a card to be chosen by (see Captain::AgentGraph#unavailable_reason):
  # nobody answers, and the turn ends through the technical-failure path (the conversation goes to staff with a note of the code).
  def nobody_can_answer?
    graph_run? && agent_run_context.graph.candidates.empty?
  end

  def no_agent_response(context)
    reason = agent_run_context.graph.unavailable_reason
    technical_failure_response({ 'kind' => Captain::Runtime::ToolFailure::TECHNICAL, 'tool' => 'agent_router', 'reason' => reason.to_s }, context)
  end

  # What a reply suggestion reads once at its start instead of with tools, so that the model spends no step on it: the patient card and
  # the upcoming appointments of the patient circle (Captain::ReplySuggestion::PatientPreload), for the agents that have the tools that
  # read them. It goes to the prompt through the run context (Concerns::Agentable). The tools stay for everything else. A preload that
  # fails is dropped with a log line: the agent then reads with its tools as it did before.
  def preload_suggestion_context(context)
    return unless preload_suggestion?
    return if council_turn?

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    preload = read_suggestion_preload(context)
    context[:suggestion_preload] = preload if preload.present?
    elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
    @callbacks[:on_suggestion_preload]&.call('parts' => PRELOAD_PARTS.select { |part| preload.key?(part) }.map(&:to_s), 'ms' => elapsed_ms)
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][ReplySuggestion] preload skipped error_class=#{e.class.name}")
  end

  def preload_suggestion?
    suggestion_run? && @conversation.present? && (graph_run? || @assistant&.persisted?)
  end

  def read_suggestion_preload(context)
    actor = suggestion_actor(context)
    return {} unless actor

    patient = Captain::ReplySuggestion::PatientPreload.build(
      assistant: actor, conversation: @conversation, tool_ids: preload_tool_ids(context)
    )
    faq = preload_faq(context)
    faq.present? ? patient.merge(faq: faq) : patient
  end

  # The message of the patient is embedded while the router decides (Captain::ReplySuggestion::FaqPreload); the nearest FAQ answers of
  # the agent that answers go to the prompt. A council has no single agent and no single question: its parts search with their tools.
  def start_faq_preload(message_to_process, context)
    @faq_preload = nil
    return unless preload_suggestion?

    @faq_preload = Captain::ReplySuggestion::FaqPreload.start(account: account, text: latest_patient_text(message_to_process, context))
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][ReplySuggestion] faq preload not started error_class=#{e.class.name}")
  end

  def preload_faq(context)
    return if @faq_preload.nil? || council_turn?

    actor = suggestion_actor(context)
    @faq_preload.matches(actor) if actor
  end

  # What the patient wrote since the clinic last answered: the messages of this turn without the send times the platform stamps on them,
  # the latest one last. A long turn is the latest message alone, which holds the question.
  def latest_patient_text(message_to_process, context)
    current = (message_to_process.is_a?(RubyLLM::Content) ? message_to_process.text : message_to_process).to_s.squish
    turn = [*unanswered_user_texts(context).map { |text| Captain::PromptClock.unstamped(text).squish }, current].reject(&:blank?).join("\n")
    turn.length > Captain::ReplySuggestion::FaqPreload::MAX_QUERY_CHARS ? current : turn
  end

  # The tools of the agent that answers. Council parts read with their own tools instead of sharing one preload.
  def preload_tool_ids(context)
    Array(suggestion_actor(context)&.allowed_agent_tool_ids)
  end

  def suggestion_actor(context)
    return @assistant unless graph_run?

    id = context[:acting_assistant_id] || @acting_assistant_id || context.dig(:state, :assistant_id)
    agent_run_context.graph.find(id) if id
  end

  # A routed reply suggestion starts with the time of a council (Captain::ReplySuggestion.budget_seconds(router: true)); when the
  # router chose one agent or staff, the rest of the run has the budget of one agent, so a slow or stuck agent run fails as soon as
  # it would without a router.
  def limit_suggestion_budget(decision)
    return unless suggestion_run? && decision && !decision.council?

    Captain::ReplySuggestion::RunControl.current&.shorten!(Captain::ReplySuggestion.budget_seconds)
  end

  # The council could not be set up. The dispatcher may already have given the conversation to the acting agent of the council
  # (saved and activated): the failure answers as it; else the holder still has the conversation.
  def council_unavailable_response(error, context)
    Rails.logger.warn("[CAPTAIN][Router] council unavailable: #{error.message}")
    @acting_assistant_id = context[:acting_assistant_id] || conversation_holder&.id
    technical_failure_response({ 'kind' => Captain::Runtime::ToolFailure::TECHNICAL, 'tool' => 'agent_router', 'reason' => 'council_unavailable' },
                               context)
  end

  # The patient asks for a live staff member: no agent runs. The agent that holds the conversation (the AI itself when nobody holds it)
  # hands it over; the response builder applies the handoff (status, the clinic's notice, a staff note). In a reply suggestion the
  # operator is told to answer.
  def routed_human_response(context)
    actor = conversation_holder
    @acting_assistant_id = actor&.id
    reason = I18n.with_locale(account.locale || I18n.default_locale) { I18n.t('captain.coordination.patient_requested_human') }
    return routed_human_suggestion if suggestion_run?

    record_routed_handoff(context, reason)
    human_handoff_response({ reason: reason }, actor&.agent_name).merge('routing_handoff' => true)
  end

  # The router decided it, not an agent: routing_human tells the outcome so (no agent is named as its author).
  def routed_human_suggestion
    note = I18n.t('captain.reply_suggestion.reasons.patient_requested_human')
    { 'response' => '', 'response_mode' => 'human', 'response_human_needed' => true, 'operator_note' => note, 'routing_human' => true }
  end

  # A suggestion never drafts a courtesy. A live courtesy with no eligible actor or holder also ends here, before dispatch or tools.
  # A live turn with a holder keeps the dispatcher's courtesy path and its action-tool prohibition.
  def no_reply_without_runner?
    @turn_decision&.no_reply? && (suggestion_run? || (@turn_decision.agent_id.nil? && conversation_holder.nil?))
  end

  # Nothing is drafted, sent or proposed (in the eval of 26.10 agents booked visits on a closing «Спасибо»). The manager sees why
  # there is no draft; routing_no_reply identifies the router's outcome, while any existing sticky agent stays the same.
  def routed_no_reply_response
    @acting_assistant_id = conversation_holder&.id
    note = I18n.t('captain.reply_suggestion.reasons.router_no_reply')
    { 'response' => '', 'response_mode' => 'suppress', 'operator_note' => note, 'routing_no_reply' => true }
  end

  # The same record the handoff tool leaves: the next turn closes the handed-off message instead of answering it again.
  def record_routed_handoff(context, reason)
    done = Captain::DoneActions.handoff_entry(reason: reason, request: Captain::Runtime::OperationScope.request(context),
                                              user_message: context[:captain_v2_current_input])
    context[:agent_session]&.record_done(done) if done
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][Router] handoff record failed error_class=#{e.class.name}")
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
      retry_context.delete(Captain::Tools::HandoffTool::AUTHORIZED_CONTEXT_KEY)
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

  # The agent the router chose runs (or the council it chose, see TurnDispatcher#run).
  def run_agent(message_to_process, context, runtime_options: {})
    time_phase('runner.run') do
      # The agents are built before the language is awaited: the decision runs meanwhile. Its answer must be in the context before the
      # run, because the prompt of the first agent call carries it.
      agent_runner = runner
      context[:patient_language] = patient_language unless context.key?(:patient_language)
      options = { context: context, max_turns: max_turns_for_run,
                  runtime_options: { llm_context: llm_context_for_run, account: account }.merge(runtime_options) }
      # A temporary (unsaved) assistant has no channel and no router: it runs alone.
      next agent_runner.run(message_to_process, **options) unless graph_run?

      turn_dispatcher.run(agent_runner, message_to_process, **options)
    end
  end

  def council_turn?
    @turn_decision&.council? == true
  end

  def max_turns_for_run
    suggestion_run? ? MAX_SUGGESTION_RUNTIME_TURNS : MAX_RUNTIME_TURNS
  end

  # A council turn is not run again: its parts already acted, and its own outcome handling covers a reply without text.
  def retry_blank_response?(response, result, attempts)
    return false unless blank_response_error_payload?(response)
    return false unless attempts < MAX_BLANK_RESPONSE_RETRIES
    return false if council_turn?

    retry_safe_completed_tools?(result.context)
  end

  def blank_response_error_payload?(response)
    response['error_class'] == BlankResponseError.name && response['error_message'] == blank_response_error.message
  end

  # A retry is safe only when the run completed no tool: a completed tool may have changed something.
  def retry_safe_completed_tools?(context)
    Array(context&.dig(:captain_v2_completed_tool_names)).empty?
  end

  def publish_blank_response_retry(result, attempt)
    current_agent = result.context&.dig(:current_agent)
    Rails.logger.warn(
      "[Captain V2] Retrying blank assistant response for assistant=#{acting_agent_id} " \
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
    @custom_guardrail_context = result.context if result.context
    @acting_assistant_id = result.context&.dig(:acting_assistant_id)
    log_agent_result(result)
    handoff_tool_called = handoff_tool_called_from_context(result.context)
    if result.respond_to?(:error) && result.error.is_a?(Captain::Safety::CustomRulesRuntime::HandoffRequired)
      @acting_assistant_id = result.error.assistant_id
      return Captain::Safety::CustomRulesRuntime.response_for(result.error)
    end
    # A technical failure of a tool ended the run (or every part of a council): the customer gets no text about it, the
    # conversation goes to staff. This is the system handoff of a failed turn, which does not need the handoff tool.
    if technical_failure_from(result.context).present? && !authorized_handoff_pending?(result.context, handoff_tool_called)
      return technical_failure_response(technical_failure_from(result.context), result.context)
    end

    if result.respond_to?(:error) && result.error.present?
      if authorized_handoff_pending?(result.context, handoff_tool_called)
        return human_handoff_response(result.context[:pending_human_handoff],
                                      result.context[:current_agent],
                                      handoff_tool_called: handoff_tool_called)
      end

      return suppressed_response({ 'response' => '' }) if provider_booking_notification_deferred?(result.context)
      if result.error.is_a?(Llm::StructuredOutputPolicy::ProviderRefusalError)
        return provider_refusal_blocked_response(result, handoff_tool_called: handoff_tool_called)
      end

      return final_error_response(result.error, result.context, handoff_tool_called: handoff_tool_called)
    end

    if result.context&.dig(:pending_response_cancellation).present?
      return response_cancellation_response(result.context[:pending_response_cancellation], result.context[:current_agent])
    end

    if authorized_handoff_pending?(result.context, handoff_tool_called)
      return human_handoff_response(result.context[:pending_human_handoff],
                                    result.context[:current_agent],
                                    handoff_tool_called: handoff_tool_called)
    end

    output = result.output
    response = output.is_a?(Hash) ? output.with_indifferent_access : { 'response' => output.to_s, 'reasoning' => '' }
    response.delete('handoff_authorized')
    # A handoff goes through the handoff tool; older or stray model values must not reach the response builder.
    response.delete('handoff_message')
    response.delete('handoff_reason')
    response.delete('council_handoff')
    response.delete('council_note')
    response.delete(PROVIDER_ERROR_AUTHORIZED_KEY)
    response.delete(MODERATION_BLOCKED_KEY)
    response.delete('safety_reason')
    response.delete('safety_block')
    response.delete(Captain::Safety::CustomRulesRuntime::RESPONSE_KEY)
    response['agent_name'] = result.context&.dig(:current_agent)
    response['agent_id'] = @acting_assistant_id
    pending_actions = Array(result.context&.dig(:captain_suggestion_pending_actions))
    response['pending_actions'] = pending_actions if pending_actions.any?
    response['council_contributors'] = result.context[:council_contributors] if result.context&.dig(:council_contributors).present?
    # Set by the council only when a part is unresolved or failed technically; the response builder then performs the handoff.
    response['council_handoff'] = result.context[:council_handoff].to_h.deep_stringify_keys if result.context&.dig(:council_handoff).present?
    # Set by the council only for a part that acted without a text for the customer, or that nobody will answer; a private note.
    response['council_note'] = result.context[:council_note].to_h.deep_stringify_keys if result.context&.dig(:council_note).present?
    # A suggestion tells the manager what a council left without a text (see ReplySuggestion::AgentOutcomeClassifier), and which
    # agent the dialog stays with (see ReplySuggestion::StickyAgent).
    if suggestion_run? && council_turn?
      response['council_turn'] = true
      response['lead_agent_id'] = council_lead_agent_id(result.context)
    end
    refs = part_refs_for(result.context)
    response['part_refs'] = refs if refs.any?
    response['handoff_tool_called'] = handoff_tool_called
    if ActiveModel::Type::Boolean.new.cast(result.context&.dig(:captain_v2_resolve_tool_called))
      response['resolve_tool_called'] = true
      resolved_transition_id = result.context&.dig(:captain_v2_resolved_status_transition_id)
      response['resolved_status_transition_id'] = resolved_transition_id if resolved_transition_id.present?
    end
    sanitize_response_artifact_ids!(response, result.context)
    return suppressed_response(response) if provider_booking_notification_deferred?(result.context)
    if !response_suppressed?(response) && Llm::CaptainResponseContentNormalizer.provider_refusal?(response['response'])
      return provider_refusal_output_response(result, handoff_tool_called: handoff_tool_called)
    end

    semantic_error = semantic_output_error(response, result.context, handoff_tool_called: handoff_tool_called)
    return semantic_output_error_response(semantic_error, response, result.context, handoff_tool_called: handoff_tool_called) if semantic_error

    return suppressed_response(response) if response_suppressed?(response)
    return human_needed_suggestion_response(response) if suggestion_run? && response_mode(response) == 'human'

    if blank_public_response?(response)
      error = blank_response_error
      return final_error_response(error, result.context, handoff_tool_called: handoff_tool_called)
    end

    if response['response'].is_a?(String)
      response['response'] = Llm::PiiSessionPseudonymizer.unmask_customer_text(response['response'])
      response['response'] = Scheduling::IinValidator.redact_customer_text(response['response'])
    end
    flag_draft!(response, result.context) if suggestion_run? && !council_turn?
    publish_tool_omission_event(response, result.context)
    moderate_output!(response, result.context&.dig(:state, :captain_runtime))
    add_playground_usage(response, result)
    response
  rescue Llm::SafetyPolicy::UnsafeContentError => e
    blocked_by_moderation_response('Agent output blocked by moderation policy', safety_reason: e.reason)
  rescue Llm::SafetyPolicy::UnavailableError => e
    blocked_by_moderation_response('Agent output blocked because moderation policy is unavailable', safety_reason: e.reason)
  end

  # A suggestion offers only the times its scheduling reads found, each under the specialist whose list holds it
  # (Captain::ReplySuggestion::DraftTimes) and gives a time under the specialist whose search found it. A claim that a booking,
  # cancellation or move was completed now is checked by DraftClaims and blocked when this run has no evidence. The draft is not changed.
  def flag_draft!(response, context)
    draft = response['response']
    flag_kind!(response, 'unverified_times') { Captain::ReplySuggestion::DraftTimes.unverified(draft: draft, context: context) }
    flag_kind!(response, 'misattributed_times') { Captain::ReplySuggestion::DraftSpecialists.misattributed(draft: draft, context: context) }
    response['reply_claim_check'] = Captain::ReplySuggestion::DraftClaims.check(draft: draft, context: context, account: account).to_s
  end

  def flag_kind!(response, key)
    flagged = yield
    return if flagged.empty?

    response[key] = flagged
    Rails.logger.info("[CAPTAIN][ReplySuggestion] draft flagged kind=#{key} count=#{flagged.size}")
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][ReplySuggestion] draft not checked kind=#{key} error_class=#{e.class.name}")
  end

  # The parts this reply answers: the plan of the request, and the actions of earlier runs that the customer was not told about
  # (their reply was dropped) and that this reply reports. They are recorded as delivered with the message. A part of a council
  # that has no text in the reply was not told, so it is not recorded as delivered (an action it did is reported by a later reply).
  # A council reply holds only the texts of the parts of its own plan and never reports the actions of earlier runs, so those
  # stay undelivered until a reply of a single agent reports them (the council sets council_untold_part_ids on every reply it
  # assembles, an empty list included).
  def part_refs_for(context)
    untold = Array(context&.dig(:council_untold_part_ids))
    planned = Array(context&.dig(:part_plan, :parts))
    undelivered = context&.key?(:council_untold_part_ids) ? [] : Captain::Runtime::PartRegistry.undelivered_outcomes(context&.dig(:parts))
    (planned + undelivered).reject { |part| untold.include?(part['id']) }.map { |part| part.slice('id', 'version') }.uniq
  end

  # The agent a council suggestion leaves the dialog with: the owner of the last part that asked the patient something (the answer
  # is its), else the first agent that wrote a part of the reply; nil when neither (the acting agent then keeps it).
  def council_lead_agent_id(context)
    planned = Array(context&.dig(:part_plan, :parts)).pluck('id')
    asking = Array(context&.dig(:parts)).select { |part| planned.include?(part['id']) && part['state'] == 'waiting_customer' }
    asking.last&.dig('executor_agent_id') || Array(context&.dig(:council_contributors)).first.to_h.with_indifferent_access[:id]
  end

  def technical_failure_from(context)
    context_value(context, :technical_failure).presence
  end

  # The response of a failed turn: no text for the customer. The response builder applies the system handoff (status open, the
  # configured handoff notice, a private note) and the note names what failed: tool, stage and reason codes, never an argument,
  # a message or a patient.
  def technical_failure_response(technical, context)
    completed = Array(context_value(context, Captain::Runtime::ToolWrapper::COMPLETED_ACTIONS_KEY)).uniq
    failure = technical.to_h.deep_stringify_keys.merge('completed' => completed)
    {
      'response' => PROVIDER_ERROR_RESPONSE,
      'reasoning' => 'Technical failure of a tool ended the run',
      'error_class' => TECHNICAL_FAILURE_ERROR_CLASS,
      'error_message' => [failure['tool'], failure['reason']].compact.join(': '),
      PROVIDER_ERROR_AUTHORIZED_KEY => true,
      'technical_failure' => failure
    }
  end

  def log_agent_result(result)
    error = result.respond_to?(:error) ? result.error : nil
    Rails.logger.info(
      "[Captain V2] Agent result assistant_id=#{acting_agent_id} conversation_id=#{@conversation&.id} " \
      "current_agent=#{result.context&.dig(:current_agent)} output_type=#{result.output.class.name} error_class=#{error&.class&.name}"
    )
  end

  def publish_tool_omission_event(response, context)
    bound_tool_ids = Array(context&.dig(:captain_v2_bound_tool_ids)).map(&:to_s).reject(&:blank?).uniq
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

  # An error that ends a run (a failure of the provider or of the model, an internal error) is a failed turn: the customer gets no
  # text of the system, the conversation goes to staff through the standard handoff (see ResponseBuilderJob#handoff_failed_turn).
  def error_response(error)
    message = error.respond_to?(:message) ? error.message : error.to_s
    with_completed_actions({
                             'response' => PROVIDER_ERROR_RESPONSE,
                             'reasoning' => "Error occurred: #{message}",
                             'error_class' => error.class.name,
                             'error_message' => message,
                             PROVIDER_ERROR_AUTHORIZED_KEY => true
                           }, @last_tool_result_context, error)
  end

  def provider_error_response(error, context, handoff_tool_called: false)
    response = {
      'response' => PROVIDER_ERROR_RESPONSE,
      'reasoning' => "Provider error occurred: #{error.message}",
      'error_class' => error.class.name,
      'error_message' => error.message
    }
    response[PROVIDER_ERROR_AUTHORIZED_KEY] = true if error.is_a?(RubyLLM::Error)
    response['handoff_tool_called'] = true if handoff_tool_called
    with_completed_actions(response, context, error)
  end

  # What the run had already done before it failed goes to the staff note (names only), as for a failure of a tool: staff must know
  # the state of the request, for example that the booking was made although the reply was not. Nothing of it reaches the customer.
  def with_completed_actions(response, context, error)
    completed = Array(context_value(context, Captain::Runtime::ToolWrapper::COMPLETED_ACTIONS_KEY)).uniq
    return response if completed.blank?

    failure = { 'kind' => Captain::Runtime::ToolFailure::TECHNICAL, 'reason' => 'run_error', 'error_class' => error.class.name,
                'completed' => completed }
    response.merge('technical_failure' => failure)
  end

  def final_error_response(error, context, handoff_tool_called: false)
    publish_zero_completion_detected_event(error, context)

    finalization_response = finalization_only_retry_response(error, context, handoff_tool_called: handoff_tool_called)
    return finalization_response if finalization_response

    provider_error_response(error, context, handoff_tool_called: handoff_tool_called)
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
  rescue Captain::Conversation::ControlGenerationStaleError
    raise
  rescue StandardError => e
    Rails.logger.warn(
      "[Captain V2] Finalization-only retry failed for assistant=#{acting_agent_id} " \
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
      response['error_class'].blank?
  end

  def finalization_only_retry_eligible?(context)
    return false if context.blank?
    return false if council_turn?
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
    # A transfer promise is never repaired by another paid model step or by a
    # regex-triggered action. The existing failed-turn outcome safely withholds it.
    return provider_error_response(error, context, handoff_tool_called: handoff_tool_called) if error.code == 'unverified_handoff_claim'

    final_error_response(error, context, handoff_tool_called: handoff_tool_called)
  end

  def semantic_output_error(response, context = nil, handoff_tool_called: false)
    return invalid_response_mode_error(response) unless response_mode_valid?(response)
    return invalid_public_response_error(response) if invalid_public_response?(response)
    return reserved_runtime_action_error(response) if reserved_runtime_action?(response)
    return provider_error_literal_error if provider_error_literal?(response)

    handoff_error = handoff_output_error(response, context, handoff_tool_called)
    return handoff_error if handoff_error
    return unsafe_suppressed_response_error if unsafe_suppressed_response?(response, context, handoff_tool_called: handoff_tool_called)

    nil
  end

  def handoff_output_error(response, context, handoff_tool_called)
    return invalid_handoff_output_error if invalid_handoff_output?(response)

    unverified_handoff_claim_error if unverified_handoff_claim?(response, context, handoff_tool_called)
  end

  def unverified_handoff_claim?(response, context, handoff_tool_called)
    return false unless response_mode(response) == 'reply'
    # These facts are server-owned and belong to this run's result context. Never
    # infer a transfer from the model output, a task/note, or conversation history.
    return false if authorized_handoff_pending?(context, handoff_tool_called) || context&.dig(:council_handoff).present?

    Captain::Assistant::HandoffClaim.asserted?(response['response'])
  end

  def unverified_handoff_claim_error
    SemanticOutputError.new('unverified_handoff_claim', 'Model output claimed staff transfer without current-turn handoff evidence')
  end

  def unsafe_suppressed_response?(response, context, handoff_tool_called: false)
    return false if suppression_allowed_for_turn?(response, context, handoff_tool_called)

    suppressed_actionable_or_transfer_claim?(response, context)
  end

  def suppression_allowed_for_turn?(response, context, handoff_tool_called)
    return true if suggestion_run? || !response_suppressed?(response)
    return true if handoff_tool_called || ActiveModel::Type::Boolean.new.cast(response['resolve_tool_called'])

    provider_booking_notification_deferred?(context) || response['council_handoff'].present?
  end

  def suppressed_actionable_or_transfer_claim?(response, context)
    patient_text = @current_patient_text.presence || patient_text_from_context(context)
    Captain::PatientIntent.actionable_request?(patient_text) ||
      Captain::PatientIntent.claims_staff_transfer?(response['reasoning']) ||
      Captain::PatientIntent.claims_staff_transfer?(response['operator_note'])
  end

  def patient_text_from_context(context)
    unanswered_user_texts(context.to_h).map { |text| Captain::PromptClock.unstamped(text).squish }.reject(&:blank?).join("\n")
  rescue StandardError
    ''
  end

  def unsafe_suppressed_response_error
    SemanticOutputError.new(
      'unsafe_suppressed_response',
      'Model output suppressed reply to an actionable patient request without handoff'
    )
  end

  # `human` (a staff member must answer) exists in a reply suggestion only: in a live conversation the handoff tool does that.
  def response_mode_valid?(response)
    response_mode(response).in?(suggestion_run? ? SUGGESTION_RESPONSE_MODES : RESPONSE_MODES)
  end

  def invalid_response_mode_error(response)
    SemanticOutputError.new(
      'invalid_response_mode',
      "Model output returned invalid response mode #{response['response_mode'].inspect}"
    )
  end

  def response_suppressed?(response)
    response_mode(response) == 'suppress'
  end

  def provider_booking_notification_deferred?(context)
    Array(context&.dig(:captain_v2_completed_tool_results)).any? do |entry|
      record = entry.to_h.with_indifferent_access
      next false unless record[:success]

      provider_booking_mutation?(record[:appointment_evidence].to_h.with_indifferent_access)
    end
  end

  def provider_booking_mutation?(evidence)
    # Only reschedules still use the legacy deferred outcome. The create tool
    # returns the provider write acknowledgement to the agent in this turn.
    return false unless evidence[:action].to_s == 'update_appointment'

    return false if evidence[:provider_status_lookup]
    return false unless evidence[:provider_confirmation_required] && evidence[:provider_command_receipt_present]
    return false unless evidence[:provider_command_id].present? && evidence[:provider_confirmation_status].present?

    evidence[:provider_command_operation] == APPOINTMENT_PROVIDER_OPERATIONS['update_appointment']
  end

  def response_mode(response)
    response['response_mode'].to_s.strip.presence || 'reply'
  end

  def suppressed_response(response)
    response.merge(
      'response' => '',
      'response_mode' => 'suppress',
      'response_suppressed' => true
    )
  end

  # A reply suggestion for which only staff can answer: no text, and operator_note tells the manager why.
  def human_needed_suggestion_response(response)
    response.merge('response' => '', 'response_mode' => 'human', 'response_human_needed' => true)
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
      "assistant=#{acting_agent_id} conversation=#{@conversation&.id} " \
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
      tool_name = record[:tool_name].to_s
      record[:success] && !Captain::HandoffNaming.transfer_tool_name?(tool_name)
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
      error_type: hash[:error_type],
      appointment_evidence: hash[:appointment_evidence]
    }.compact
  end

  def tool_result_counts(records)
    records.each_with_object({}) do |record, counts|
      tool_name = record[:tool_name].to_s
      counts[tool_name] ||= 0
      counts[tool_name] += 1
    end
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

  def authorized_handoff_pending?(context, handoff_tool_called)
    handoff_tool_called && context&.dig(:pending_human_handoff).present?
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
      account_id: account.id,
      captain_runtime: runtime_preferences_for_run,
      captain_scheduling_grounding_guard_enabled: account.feature_enabled?('captain_scheduling_grounding_guard')
    }
    # The agent of a run alone is known up front. In a channel the router chooses it, and its activation sets everything that is the
    # agent's own (its configuration, preferences and prompt context, see Captain::AgentRunContext#activate).
    if @assistant
      state[:assistant_id] = @assistant.id
      state[:assistant_config] = @assistant.config
    end
    state[:source] = @source if @source.present?
    state[:playground_thinking_effort] = @test_overrides[:thinking_effort] if @source == 'playground' && @test_overrides.key?(:thinking_effort)
    state[:captain_control_generation] = @response_fence[:control_generation] if @response_fence.key?(:control_generation)
    state[:captain_response_fence] = @response_fence if @conversation.present? && @response_fence.present?
    state[:runtime_clock] = runtime_clock_state

    if @playground_session&.trial?
      state.merge!(@playground_session.state)
    else
      time_phase('build_conversation_state') { build_conversation_state(state) } if @conversation
      state.merge!(@playground_session.state) if @playground_session
    end
    state[:prompt_context] = time_phase('prompt_context_state') { @assistant.prompt_context_state(state) } if @assistant
    state
  end

  # message_sent_at: the send time of the patient message being answered (a suggestion may answer a message of an earlier day).
  def runtime_clock_state
    timezone = runtime_timezone
    now = Time.current
    local_now = now.in_time_zone(timezone)

    {
      now_utc: now.utc.iso8601,
      now_local: local_now.iso8601,
      timezone: timezone,
      date_local: local_now.to_date.iso8601,
      time_local: local_now.strftime('%H:%M:%S'),
      message_sent_at: Captain::PromptClock.parse_time(@current_input_sent_at)&.utc&.iso8601
    }.compact
  end

  def runtime_timezone
    return @playground_session.scenario.data['timezone'] if @playground_session&.trial?

    configured_timezone = @conversation&.inbox&.timezone.presence || Time.zone.name
    return configured_timezone if Time.find_zone(configured_timezone).present?

    'UTC'
  rescue StandardError
    'UTC'
  end

  def request_event_context(context)
    state = context[:state] || {}
    conversation = state[:conversation] || {}

    @captain_request_id = context[:agent_request_id] || @request_id || SecureRandom.uuid
    {
      request_id: @captain_request_id,
      feature: 'assistant',
      runtime_mode: 'captain_runtime',
      account_id: state[:account_id],
      user_id: Current.user&.id,
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
    reply_notification = Captain::ReplyNotificationContext.for(
      account: account, conversation: @conversation, incoming_message_id: @incoming_message_id
    )
    state[:conversation][:reply_notification] = reply_notification if reply_notification.present?
    add_related_record_state(state)
    state.compact!
  end

  def base_conversation_state
    {
      conversation: Captain::ContextFields.conversation_state_for(@conversation),
      channel_type: @conversation.inbox&.channel_type,
      reply_window: reply_window_state
    }
  end

  def reply_window_state
    return {} unless @conversation&.inbox&.channel.is_a?(Channel::Whatsapp)

    # The window is the customer's number's, not the conversation's, see Conversations::MessageWindowService.
    last_incoming_at = Conversations::MessageWindowService.last_incoming_timestamps([@conversation])[@conversation.id]
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
      account: account,
      conversation: @conversation,
      accessible_inboxes: thread_accessible_inboxes
    )
    state[:deal] = Captain::ContextFields.deal_state_for(account: account, conversation: @conversation, deal: scoped_event_deal)
    state[:task] = Captain::ContextFields.task_state_for(account: account, conversation: @conversation)
    state[:appointment] = Captain::ContextFields.appointment_state_for(
      account: account, conversation: @conversation, patient_scope: true
    )
    state[:campaign] = slice_attrs(@conversation.campaign, CAMPAIGN_STATE_ATTRIBUTES) if @conversation.campaign
    state[:contact_inbox] = slice_attrs(@conversation.contact_inbox, CONTACT_INBOX_STATE_ATTRIBUTES) if @conversation.contact_inbox
  end

  # The AI works across every channel of its workspace: it sees the person's thread in all of them (there is no per-agent channel list).
  def thread_accessible_inboxes
    account.inboxes.includes(:channel).to_a if account.feature_enabled?('communication_threads')
  end

  def scoped_event_deal
    return unless @event_deal&.account_id == account.id
    return unless Captain::DealContext.new(account: account, conversation: @conversation).deals.exists?(id: @event_deal.id)

    @event_deal
  end

  def slice_attrs(record, keys)
    record.attributes.symbolize_keys.slice(*keys)
  end

  # The agents of the channel, built lazily: only the agent the router chooses builds its tools.
  def build_and_wire_agents
    agent_options = {
      model_override: @test_overrides[:model],
      temperature_override: @test_overrides[:temperature],
      suggestion_tools: (true if suggestion_run?)
    }.compact
    return [@assistant.agent(**agent_options)] unless graph_run?

    agents = agent_run_context.runtime_agents(overrides: agent_options)
    return agents unless @turn_decision&.no_reply? && @turn_decision.agent_id.nil?

    holder = conversation_holder
    return agents if holder.nil? || agents.any? { |agent| agent.name == holder.agent_name }

    # A holder without a routing card is still an eligible channel member. Dispatch selected it for this courtesy and set ACK.
    agents + [holder.agent(**agent_options)]
  end

  def agent_run_context
    @agent_run_context ||= begin
      options = { scope: @scope, conversation: @conversation, playground: @playground_session, fence: @response_fence }
      if suggestion_run?
        options[:ephemeral_session] = true
        # The agent that leads the dialog of the suggestions (the saved session has none while the AI only suggests).
        options[:sticky_agent_id] = Captain::ReplySuggestion::StickyAgent.read(@conversation)
      end
      Captain::AgentRunContext.new(**options)
    end
  end

  def suggestion_run?
    @source.to_s == 'reply_suggestion'
  end

  def runtime_preferences_for_run
    Captain::AssistantSafetyPreferences.for(assistant: @assistant, feature: :assistant, account: account)
  end

  def add_playground_latency(response, started_at)
    return response unless @source == 'playground' && response.is_a?(Hash) && started_at

    elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
    response.merge('response_latency_ms' => elapsed_ms)
  end

  def with_agent_identity(response)
    return response unless response.is_a?(Hash)

    response = response.merge('captain_request_id' => @captain_request_id) if @captain_request_id.present?
    return response unless graph_run?

    # No agent produced the output (nobody holds the conversation): it is the AI itself, and names no agent.
    actor = agent_run_context.graph.find(@acting_assistant_id) if @acting_assistant_id
    response.merge('agent_id' => actor&.id, 'agent_display_name' => actor&.name)
  end

  def add_playground_usage(response, result)
    return add_suggestion_usage(response, result) if suggestion_run?
    return unless @source == 'playground' && result.respond_to?(:usage)

    tokens = result.usage.thinking_tokens.to_i if result.usage.respond_to?(:thinking_tokens)
    tokens ||= 0
    response['reported_reasoning_tokens'] = tokens if tokens.positive?
  end

  def add_suggestion_usage(response, result)
    usage = result.usage if result.respond_to?(:usage)
    total = usage.respond_to?(:total_tokens) ? usage.total_tokens.to_i : 0
    return unless total.positive?

    response['usage'] ||= {
      'prompt_tokens' => usage.input_tokens.to_i,
      'completion_tokens' => usage.output_tokens.to_i,
      'total_tokens' => total
    }
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
    handoff_tool_name = Captain::Tools::HandoffTool.new(nil).name

    # This callback feeds ResponseBuilderJob and blank-response retry safety even when OTEL is disabled.
    runner.on_tool_complete do |tool_name, tool_result, context_wrapper|
      track_handoff_usage(tool_name, handoff_tool_name, tool_result, context_wrapper)
      track_completed_tool_usage(tool_name, tool_result, context_wrapper)
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
    # The run of a council part is not "the last run": the error fallback must not be built from one part's results.
    remember_last_tool_result_context(context_wrapper) unless context_wrapper.context[:part_run]
  end

  def remember_last_tool_result_context(context_wrapper)
    @last_tool_result_context = context_wrapper.context.deep_dup
  rescue StandardError
    @last_tool_result_context = context_wrapper.context
  end

  def track_completed_tool_result(tool_name, tool_result, context_wrapper)
    normalized = Captain::ToolResult.normalize(tool_result)
    context_wrapper.context[:captain_v2_completed_tool_results] ||= []
    context_wrapper.context[:captain_v2_completed_tool_results] << completed_tool_result_record(
      tool_name, normalized, context_wrapper.context.dig(:state, :assistant_id)
    )
    context_wrapper.context[:captain_v2_completed_tool_results] =
      context_wrapper.context[:captain_v2_completed_tool_results].last(MAX_COMPLETED_TOOL_RESULT_RECORDS)
  end

  def completed_tool_result_record(tool_name, normalized_result, actor_id)
    {
      tool_name: tool_name.to_s,
      success: !Captain::ToolResult.error?(normalized_result),
      retryable: normalized_result[:retryable],
      data_type: tool_payload_type(normalized_result[:data]),
      message_type: tool_payload_type(normalized_result[:message]),
      error_type: tool_payload_type(normalized_result[:error]),
      appointment_evidence: appointment_evidence(tool_name, normalized_result, actor_id)
    }.compact
  end

  def appointment_evidence(tool_name, normalized_result, actor_id)
    canonical_name = APPOINTMENT_MUTATION_TOOL_NAMES.find do |name|
      tool_name.to_s == name || tool_name.to_s.end_with?("__#{name}") || tool_name.to_s.end_with?(":#{name}")
    end
    payload = structured_tool_payload(normalized_result[:data]) || structured_tool_payload(normalized_result[:message])
    return if payload.blank?
    return appointment_status_evidence(payload) if appointment_status_tool?(tool_name)
    return if canonical_name.blank?

    if !@playground_session&.trial? && canonical_name == 'update_appointment' && payload[:success] && payload[:appointment_id].present?
      return provider_move_evidence(payload, actor_id)
    end

    appointment = payload[:appointment].to_h.with_indifferent_access
    receipt = payload[:provider_command_receipt].to_h.with_indifferent_access
    provider_command = receipt[:command].to_h.with_indifferent_access
    provider_confirmation_required = if payload.key?(:provider_confirmation_required)
                                       ActiveModel::Type::Boolean.new.cast(payload[:provider_confirmation_required])
                                     end
    {
      action: payload[:action].presence || canonical_name,
      appointment_id: payload[:appointment_id].presence || appointment[:id],
      provider_confirmation_status: payload[:provider_confirmation_status].presence,
      provider_confirmed: ActiveModel::Type::Boolean.new.cast(payload[:provider_confirmed]),
      provider_confirmation_required: provider_confirmation_required,
      provider_command_receipt_present: receipt.present?,
      provider_command_id: provider_command[:id],
      provider_command_operation: provider_command[:operation],
      provider_reception_code: provider_command[:provider_reception_code],
      provider_command_idempotency_key: provider_command[:idempotency_key],
      status: payload[:status].presence || appointment[:status],
      service_id: payload[:service_id].presence || appointment[:service_id],
      resource_id: payload[:resource_id].presence || appointment[:resource_id],
      starts_at: payload[:starts_at].presence || appointment[:starts_at],
      ends_at: payload[:ends_at].presence || appointment[:ends_at]
    }.compact
  end

  def provider_move_evidence(payload, actor_id)
    appointment = account.scheduling_appointments.find_by(id: payload[:appointment_id])
    return if appointment.blank?

    command = Integrations::Medelement::ProviderCommand.where(
      account_id: account.id, appointment_id: appointment.id, operation: 'move_reception'
    ).order(created_at: :desc, id: :desc).first
    return if command.blank? || command.request_snapshot.dig('actor', 'id').to_s != actor_id.to_s

    {
      action: 'update_appointment', appointment_id: appointment.id,
      provider_confirmation_required: true, provider_command_receipt_present: true,
      provider_command_id: command.id, provider_command_operation: command.operation,
      provider_confirmation_status: command.status
    }
  end

  def appointment_status_tool?(tool_name)
    tool_name.to_s == APPOINTMENT_STATUS_TOOL_NAME || tool_name.to_s.end_with?("__#{APPOINTMENT_STATUS_TOOL_NAME}") ||
      tool_name.to_s.end_with?(":#{APPOINTMENT_STATUS_TOOL_NAME}")
  end

  def appointment_status_evidence(payload)
    receipt = payload[:provider_command_receipt].to_h.with_indifferent_access
    command = receipt[:command].to_h.with_indifferent_access
    operation = command[:operation].to_s
    action = 'create_appointment' if operation.start_with?('create')
    action ||= 'update_appointment' if operation.start_with?('update', 'move')
    return if action.blank?

    {
      action: action,
      appointment_id: receipt[:appointment_id].presence || command[:appointment_id],
      provider_confirmation_status: command[:status],
      provider_confirmed: command[:status] == 'succeeded',
      provider_confirmation_required: true,
      provider_command_receipt_present: receipt.present?,
      provider_command_id: command[:id],
      provider_command_operation: command[:operation],
      provider_reception_code: command[:provider_reception_code],
      provider_command_idempotency_key: command[:idempotency_key],
      provider_status_lookup: true
    }.compact
  end

  def structured_tool_payload(value)
    return value.to_h.with_indifferent_access if value.respond_to?(:to_h)
    return unless value.is_a?(String) && value.bytesize <= MAX_TOOL_ARTIFACT_SCAN_BYTES

    parsed = JSON.parse(value)
    parsed.with_indifferent_access if parsed.is_a?(Hash)
  rescue JSON::ParserError
    nil
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

  def track_handoff_usage(tool_name, handoff_tool_name, tool_result, context_wrapper)
    return unless context_wrapper&.context
    return unless tool_name.to_s == handoff_tool_name

    handoff_authorized = context_wrapper.context.delete(Captain::Tools::HandoffTool::AUTHORIZED_CONTEXT_KEY)
    return unless handoff_authorized
    return if Captain::ToolResult.error?(Captain::ToolResult.normalize(tool_result))
    return if context_wrapper.context[:pending_human_handoff].blank?

    context_wrapper.context[:captain_v2_handoff_tool_called] = true
  end

  def write_credits_used_metadata(context_wrapper)
    root_span = context_wrapper&.context&.dig(:__otel_tracing, :root_span)
    return unless root_span

    credit_used = handoff_tool_called_from_context(context_wrapper.context) ? 'false' : 'true'
    root_span.set_attribute(format(ATTR_LANGFUSE_METADATA, 'credit_used'), credit_used)
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
    @current_input_sent_at = last_user_message_sent_at(message_history)
    message_to_process = extract_last_user_message(message_history)
    context = build_context(message_history_without_last_user_message(message_history))
    if @playground_session
      context[:session_id] = "playground_#{@playground_session.id}"
      context[:playground_session] = @playground_session
    end
    context[:captain_v2_current_input] = message_to_process
    @custom_guardrail_context = context
    enrich_context_with_trace_payload!(context, message_history, message_to_process)
    [message_to_process, context]
  end

  # The platform safety check of the input. It runs while the router decides; a blocked input discards the decision.
  def moderate_input(message_to_process, context)
    Llm::SafetyPolicy.check!(
      feature: :assistant,
      stage: :input,
      content: input_with_unanswered_messages(message_to_process, context),
      account: account,
      preferences: context.dig(:state, :captain_runtime)
    )
    nil
  rescue Llm::SafetyPolicy::UnsafeContentError => e
    blocked_by_moderation_response('Agent input blocked by moderation policy', safety_reason: e.reason)
  rescue Llm::SafetyPolicy::UnavailableError => e
    blocked_by_moderation_response('Agent input blocked because moderation policy is unavailable', safety_reason: e.reason)
  end

  # The custom input rules are one workspace setting (Captain::AccountSettings), the same for every agent: they are checked once,
  # before the decision is applied, for the agent that holds the conversation, so that a rule's handoff names the agent the session
  # names (the response builder drops any other), or none when nobody holds it. A staff request runs none (no agent answers). Zero cost
  # without rules.
  def check_custom_input_rules!(message_to_process, context)
    return if @turn_decision&.human?

    @acting_assistant_id = conversation_holder&.id
    Captain::Safety::CustomRulesRuntime.check_input!(
      account: account, agent_id: @acting_assistant_id, context: context, text: message_to_process
    )
  end

  def moderate_output!(response, runtime_preferences)
    Llm::SafetyPolicy.check!(
      feature: :assistant,
      stage: :output,
      content: response['response'],
      account: account,
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
        "[CAPTAIN][Timing] assistant_id=#{acting_agent_id} conversation_id=#{@conversation&.id} " \
        "phase=#{name} duration_ms=#{duration_ms}"
      )
    end
  end

  def provider_refusal_output_response(result, handoff_tool_called: false)
    error = Llm::StructuredOutputPolicy::ProviderRefusalError.new('Provider returned a safety refusal response')
    refusal_result = Captain::Runtime::Result.new(
      output: nil, messages: [], usage: (result.usage if result.respond_to?(:usage)), error: error, context: result.context
    )
    provider_refusal_blocked_response(refusal_result, handoff_tool_called: handoff_tool_called)
  end

  def provider_refusal_blocked_response(result, handoff_tool_called: false)
    context = result.context
    error = result.error
    if !suggestion_run? && Array(context_value(context, Captain::Runtime::ToolWrapper::COMPLETED_ACTIONS_KEY)).any?
      return provider_error_response(error, context, handoff_tool_called: handoff_tool_called)
    end

    response = blocked_by_moderation_response(
      "Provider safety refusal stopped the response: #{error&.message}",
      safety_reason: 'provider_refusal'
    )
    attach_refusal_metadata!(response, result, handoff_tool_called: handoff_tool_called)
  end

  def attach_refusal_metadata!(response, result, handoff_tool_called: false)
    context = result.context
    response['agent_name'] = context[:current_agent] if context&.dig(:current_agent).present?
    response['agent_id'] = @acting_assistant_id if @acting_assistant_id.present?
    pending_actions = Array(context&.dig(:captain_suggestion_pending_actions))
    response['pending_actions'] = pending_actions if pending_actions.any?
    response['handoff_tool_called'] = true if handoff_tool_called
    add_playground_usage(response, result)
    response
  end

  def blocked_by_moderation_response(reason, safety_reason: nil)
    {
      'response' => 'conversation_handoff',
      'reasoning' => reason,
      MODERATION_BLOCKED_KEY => true,
      'safety_reason' => safety_reason.to_s,
      'safety_block' => Captain::OutcomeFacts.safety_kind(safety_reason)
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
    outcome_signal = handoff_payload[:outcome_signal].presence || handoff_payload['outcome_signal'].presence

    # The customer notice is written by Captain::CustomerNoticeService from the workspace settings, never by the agent.
    response = {
      'response' => 'conversation_handoff',
      'reasoning' => reason.present? ? "Human handoff requested: #{reason}" : 'Human handoff requested',
      'handoff_reason' => reason,
      'handoff_outcome_signal' => outcome_signal,
      'handoff_authorized' => true,
      'agent_name' => agent_name
    }
    response['handoff_tool_called'] = true if handoff_tool_called
    response.compact
  end
end
