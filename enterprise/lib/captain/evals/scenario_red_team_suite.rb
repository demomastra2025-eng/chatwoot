# frozen_string_literal: true

class Captain::Evals::ScenarioRedTeamSuite
  SUITE_ID = 'captain.scenario_red_team'
  DEFAULT_CASES_PATH = Rails.root.join('config/llm_evals/captain_scenario_red_team.yml')

  UnsafeLiveCaseError = Class.new(StandardError)

  def initialize(**attributes)
    @account = attributes.fetch(:account)
    @cases_path = Pathname.new(attributes.fetch(:cases_path, DEFAULT_CASES_PATH))
    @max_cases = attributes[:max_cases].presence&.to_i
    @captain_agent_factory = attributes[:captain_agent_factory] || attributes[:agent_factory]
    @attacker_client = attributes.key?(:attacker_client) ? attributes[:attacker_client] : open_router_client(:user_simulator)
    @judge_client = attributes.key?(:judge_client) ? attributes[:judge_client] : open_router_client(:judge)
    @cache_store = attributes.fetch(:cache_store, Rails.cache)
  end

  def call
    Llm::Evals::Result.new(
      suite_id: SUITE_ID,
      prompt_id: nil,
      prompt_sha: nil,
      model: configured_model,
      cases: eval_cases.map { |eval_case| evaluate_case(eval_case) }
    )
  end

  private

  def eval_cases
    cases = Llm::Evals::CaseLoader.new(path: @cases_path).load
    return cases.first(@max_cases) if @max_cases&.positive?

    cases
  end

  def evaluate_case(eval_case)
    assert_live_case_safe!(eval_case)

    trace_collector = Llm::Evals::TraceCollector.new(trace_id: trace_id_for(eval_case), redact_raw_content: true)
    result = build_runner(eval_case, trace_collector).call

    result.to_case_result.merge(
      artifact: Llm::Evals::Scenario::Artifact.build(result: result, trace_events: trace_collector.events)
    )
  rescue StandardError => e
    error_case_result(eval_case, e)
  end

  def build_runner(eval_case, trace_collector)
    input = eval_case.fetch(:input, {})

    Llm::Evals::Scenario::Runner.new(
      id: eval_case[:id],
      description: eval_case[:description],
      tags: eval_case[:tags],
      expected: eval_case.fetch(:expected, {}),
      fixtures: input[:fixtures] || {},
      account: @account,
      max_turns: input[:max_turns],
      autopilot: true,
      autopilot_turns: input[:autopilot_turns] || 2,
      agents: agents_for(eval_case),
      trace_collector: trace_collector
    )
  end

  def agents_for(eval_case)
    [
      red_team_user_agent(eval_case),
      captain_agent(eval_case),
      judge_agent(eval_case)
    ]
  end

  def red_team_user_agent(eval_case)
    input = eval_case.fetch(:input, {})

    Captain::Evals::Scenario::RedTeamUserAgent.new(
      objective: input[:objective],
      attack_prompts: input[:attack_prompts],
      success_markers: input[:success_markers],
      client: @attacker_client,
      cache_key: eval_case[:id],
      cache_store: @cache_store
    )
  end

  def captain_agent(eval_case)
    return @captain_agent_factory.call(eval_case: eval_case, account: @account) if @captain_agent_factory

    Captain::Evals::Scenario::CaptainAgentAdapter.new(
      assistant: resolve_assistant(eval_case),
      conversation: resolve_conversation(eval_case)
    )
  end

  def judge_agent(eval_case)
    input = eval_case.fetch(:input, {})

    Llm::Evals::Scenario::JudgeAgent.new(
      criteria: input.dig(:judge, :criteria) || input[:criteria],
      expected: eval_case.fetch(:expected, {}),
      client: @judge_client,
      cache_key: eval_case[:id],
      cache_store: @cache_store,
      terminal_on_pass: false
    )
  end

  def open_router_client(mode)
    Llm::Evals::OpenRouterClient.new(account: @account, mode: mode, privacy_profile: :sensitive)
  end

  def assert_live_case_safe!(eval_case)
    return if @captain_agent_factory

    input = eval_case.fetch(:input, {})
    return if truthy?(input[:allow_mutations])

    raise UnsafeLiveCaseError, 'unsafe_live_red_team_requires_isolated_account_and_allow_mutations'
  end

  def resolve_assistant(eval_case)
    relation = Captain::Assistant.where(account: @account)
    assistant_id = eval_case.dig(:input, :assistant_id).presence || eval_case.dig(:input, :fixtures, :assistant_id).presence
    assistant = assistant_id ? relation.find_by(id: assistant_id) : relation.order(:id).first
    return assistant if assistant

    raise Captain::Evals::ScenarioSimulationSuite::MissingAssistantError, 'captain_assistant_required'
  end

  def resolve_conversation(eval_case)
    conversation_id = eval_case.dig(:input, :conversation_id).presence || eval_case.dig(:input, :fixtures, :conversation_id).presence
    return if conversation_id.blank?

    Conversation.where(account: @account).find(conversation_id)
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
