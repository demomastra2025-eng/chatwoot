# frozen_string_literal: true

class Captain::Evals::ScenarioSuite
  SUITE_ID = 'captain.scenarios'
  DEFAULT_CASES_PATH = Rails.root.join('config/llm_evals/captain_scenarios.yml')

  def initialize(cases_path: DEFAULT_CASES_PATH)
    @cases_path = Pathname.new(cases_path)
  end

  def call
    ::Llm::Evals::Result.new(
      suite_id: SUITE_ID,
      prompt_id: nil,
      prompt_sha: nil,
      model: nil,
      cases: eval_cases.map { |eval_case| evaluate_case(eval_case) }
    )
  end

  private

  def eval_cases
    @eval_cases ||= ::Llm::Evals::CaseLoader.new(path: @cases_path).load
  end

  def evaluate_case(eval_case)
    build_runner(eval_case).call.to_case_result
  rescue StandardError => e
    error_case_result(eval_case, e)
  end

  def build_runner(eval_case)
    ::Llm::Evals::Scenario::Runner.new(
      id: eval_case[:id],
      description: eval_case[:description],
      tags: eval_case[:tags],
      script: eval_case.dig(:input, :script),
      expected: eval_case.fetch(:expected, {}),
      fixtures: eval_case.dig(:input, :fixtures) || {},
      max_turns: eval_case.dig(:input, :max_turns)
    )
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
