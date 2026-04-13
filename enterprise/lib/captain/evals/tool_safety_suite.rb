# frozen_string_literal: true

module Captain
  module Evals
    class ToolSafetySuite
      include ::Llm::Evals::OfflineModerationRuntime

      SUITE_ID = 'captain.tool_safety'.freeze
      DEFAULT_CASES_PATH = Rails.root.join('config/llm_evals/tool_safety.yml')

      def initialize(cases_path: DEFAULT_CASES_PATH)
        @cases_path = cases_path
      end

      def call
        report_cases = eval_cases.map { |eval_case| evaluate_case(eval_case) }

        ::Llm::Evals::Result.new(
          suite_id: SUITE_ID,
          prompt_id: nil,
          prompt_sha: nil,
          model: nil,
          cases: report_cases
        )
      end

      private

      def eval_cases
        @eval_cases ||= ::Llm::Evals::CaseLoader.new(path: @cases_path).load
      end

      def evaluate_case(eval_case)
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        actual = execute(eval_case[:input])
        failures = compare(actual, eval_case[:expected])

        {
          id: eval_case[:id],
          description: eval_case[:description],
          tags: eval_case[:tags],
          status: failures.empty? ? 'pass' : 'fail',
          expected: eval_case[:expected],
          actual: actual,
          failures: failures,
          duration_ms: elapsed_ms(started_at)
        }.compact
      rescue StandardError => e
        {
          id: eval_case[:id],
          description: eval_case[:description],
          tags: eval_case[:tags],
          status: 'error',
          expected: eval_case[:expected],
          actual: { error: "#{e.class.name}: #{e.message}" },
          failures: ['runtime_error'],
          duration_ms: elapsed_ms(started_at)
        }.compact
      end

      def execute(input)
        with_provider_mode(input[:provider_mode]) do
          result =
            case input.fetch(:kind).to_s
            when 'result', 'results', 'tool_results'
              Captain::ToolSafety.check_result!(
                feature: input.fetch(:feature).to_sym,
                result: input[:content],
                preferences: input[:preferences]
              )
            else
              Captain::ToolSafety.check_arguments!(
                feature: input.fetch(:feature).to_sym,
                arguments: input[:content],
                preferences: input[:preferences]
              )
            end

          {
            status: result.status.to_s,
            reason: result.reason&.to_s
          }.compact
        rescue ::Llm::SafetyPolicy::UnsafeContentError => e
          {
            status: 'blocked',
            reason: e.reason.to_s,
            rule: e.rule&.to_s,
            blocked_message: Captain::ToolSafety.blocked_message(stage: e.stage, error: e)
          }.compact
        rescue ::Llm::SafetyPolicy::UnavailableError => e
          {
            status: 'unavailable',
            reason: e.reason.to_s,
            blocked_message: Captain::ToolSafety.blocked_message(stage: e.stage, error: e)
          }
        end
      end

      def compare(actual, expected)
        failures = []
        expected = expected.deep_symbolize_keys

        if expected.key?(:status) && actual[:status] != expected[:status].to_s
          failures << "expected status=#{expected[:status].inspect}, got #{actual[:status].inspect}"
        end

        if expected.key?(:reason) && actual[:reason].to_s != expected[:reason].to_s
          failures << "expected reason=#{expected[:reason].inspect}, got #{actual[:reason].inspect}"
        end

        if expected.key?(:rule) && actual[:rule].to_s != expected[:rule].to_s
          failures << "expected rule=#{expected[:rule].inspect}, got #{actual[:rule].inspect}"
        end

        Array(expected[:blocked_message_includes]).each do |fragment|
          next if actual[:blocked_message].to_s.include?(fragment.to_s)

          failures << "blocked_message missing fragment: #{fragment}"
        end

        failures
      end

      def elapsed_ms(started_at)
        ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
      end
    end
  end
end
