# frozen_string_literal: true

class Captain::Evals::ScenarioSimulationSuite
  SUITE_ID = 'captain.scenario_simulation'
  DEFAULT_CASES_PATH = Rails.root.join('config/llm_evals/captain_scenario_simulation.yml')
  MUTATING_TAGS = %w[mutating_tool mutation write destructive crm_update task_update appointment_update].freeze

  UnsafeLiveCaseError = Class.new(StandardError)
  MissingAssistantError = Class.new(StandardError)

  def initialize(**attributes)
    @account = attributes.fetch(:account)
    @cases_path = Pathname.new(attributes.fetch(:cases_path, DEFAULT_CASES_PATH))
    @max_cases = attributes[:max_cases].presence&.to_i
    @captain_agent_factory = attributes[:captain_agent_factory] || attributes[:agent_factory]
    @user_client = attributes.key?(:user_client) ? attributes[:user_client] : open_router_client(:user_simulator)
    @judge_client = attributes.key?(:judge_client) ? attributes[:judge_client] : open_router_client(:judge)
    @cache_store = attributes.fetch(:cache_store, Rails.cache)
  end

  def call
    ::Llm::Evals::Result.new(
      suite_id: SUITE_ID,
      prompt_id: nil,
      prompt_sha: nil,
      model: configured_model,
      cases: eval_cases.map { |eval_case| evaluate_case(eval_case) }
    )
  end

  private

  def eval_cases
    cases = ::Llm::Evals::CaseLoader.new(path: @cases_path).load
    return cases.first(@max_cases) if @max_cases&.positive?

    cases
  end

  def evaluate_case(eval_case)
    assert_live_case_safe!(eval_case)

    trace_collector = ::Llm::Evals::TraceCollector.new(trace_id: trace_id_for(eval_case), redact_raw_content: true)
    result = build_runner(eval_case, trace_collector).call

    result.to_case_result.merge(
      artifact: ::Llm::Evals::Scenario::Artifact.build(result: result, trace_events: trace_collector.events)
    )
  rescue StandardError => e
    error_case_result(eval_case, e)
  end

  def build_runner(eval_case, trace_collector)
    ::Llm::Evals::Scenario::Runner.new(**runner_attributes(eval_case, trace_collector))
  end

  def runner_attributes(eval_case, trace_collector)
    input = eval_case.fetch(:input, {})
    attributes = {
      id: eval_case[:id],
      description: eval_case[:description],
      tags: eval_case[:tags],
      expected: eval_case.fetch(:expected, {}),
      fixtures: input[:fixtures] || {},
      account: @account,
      max_turns: input[:max_turns],
      agents: agents_for(eval_case),
      trace_collector: trace_collector
    }.compact

    if input[:script].present?
      attributes[:script] = input[:script]
    else
      attributes[:autopilot] = input.key?(:autopilot) ? input[:autopilot] : true
      attributes[:autopilot_turns] = input[:autopilot_turns]
    end

    attributes
  end

  def agents_for(eval_case)
    [
      user_simulator_agent(eval_case),
      captain_agent(eval_case),
      judge_agent(eval_case)
    ].compact
  end

  def user_simulator_agent(eval_case)
    input = eval_case.fetch(:input, {})
    config = input.fetch(:user_simulator, {})

    ::Llm::Evals::Scenario::UserSimulatorAgent.new(
      description: eval_case[:description],
      persona: config[:persona],
      system_prompt: config[:system_prompt],
      scripted_messages: config[:scripted_messages],
      client: @user_client,
      cache_key: eval_case[:id],
      cache_store: @cache_store,
      cache_namespace: 'user_simulator'
    )
  end

  def captain_agent(eval_case)
    return @captain_agent_factory.call(eval_case: eval_case, account: @account) if @captain_agent_factory

    ::Captain::Evals::Scenario::CaptainAgentAdapter.new(
      assistant: resolve_assistant(eval_case),
      conversation: resolve_conversation(eval_case)
    )
  end

  def judge_agent(eval_case)
    input = eval_case.fetch(:input, {})
    config = input.fetch(:judge, {})

    ::Llm::Evals::Scenario::JudgeAgent.new(
      criteria: config[:criteria] || input[:criteria],
      expected: eval_case.fetch(:expected, {}),
      client: @judge_client,
      cache_key: eval_case[:id],
      cache_store: @cache_store,
      cache_namespace: 'judge'
    )
  end

  def open_router_client(mode)
    ::Llm::Evals::OpenRouterClient.new(account: @account, mode: mode, privacy_profile: :sensitive)
  end

  def assert_live_case_safe!(eval_case)
    input = eval_case.fetch(:input, {})
    return if truthy?(input[:allow_mutations])

    unsafe_tags = Array(eval_case[:tags]).map(&:to_s) & MUTATING_TAGS
    return if unsafe_tags.blank?

    raise UnsafeLiveCaseError, "unsafe_live_scenario_requires_allow_mutations: #{unsafe_tags.join(',')}"
  end

  def resolve_assistant(eval_case)
    relation = ::Captain::Assistant.where(account: @account)
    assistant_id = eval_case.dig(:input, :assistant_id).presence || eval_case.dig(:input, :fixtures, :assistant_id).presence
    assistant = assistant_id ? relation.find_by(id: assistant_id) : relation.order(:id).first
    return assistant if assistant

    raise MissingAssistantError, 'captain_assistant_required'
  end

  def resolve_conversation(eval_case)
    conversation_id = eval_case.dig(:input, :conversation_id).presence || eval_case.dig(:input, :fixtures, :conversation_id).presence
    return if conversation_id.blank?

    ::Conversation.where(account: @account).find(conversation_id)
  end

  def configured_model
    return unless @account.respond_to?(:captain_models)

    @account.captain_models.to_h['assistant']
  end

  def trace_id_for(eval_case)
    "evals:#{SUITE_ID}:#{eval_case[:id]}:#{SecureRandom.hex(4)}"
  end

  def truthy?(value)
    value == true || value.to_s == 'true'
  end

  def error_case_result(eval_case, error)
    {
      id: eval_case[:id],
      description: eval_case[:description],
      tags: eval_case[:tags],
      status: 'error',
      expected: eval_case[:expected],
      actual: { error: "#{error.class.name}: #{error.message}" },
      failures: ['runtime_error'],
      duration_ms: 0
    }.compact
  end
end
