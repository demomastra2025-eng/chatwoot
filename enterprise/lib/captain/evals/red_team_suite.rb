# frozen_string_literal: true

require 'ruby_llm/tribunal'

module Captain
  module Evals
    class RedTeamSuite
      SUITE_ID = 'captain.red_team'
      DEFAULT_CASES_PATH = Rails.root.join('config/llm_evals/red_team.yml')

      def initialize(cases_path: DEFAULT_CASES_PATH)
        @cases_path = cases_path
      end

      def call
        ::Llm::Evals::Result.new(
          suite_id: SUITE_ID,
          prompt_id: nil,
          prompt_sha: nil,
          model: 'ruby_llm_tribunal_red_team',
          cases: eval_cases.flat_map { |eval_case| evaluate_case(eval_case) }
        )
      end

      private

      def eval_cases
        @eval_cases ||= ::Llm::Evals::CaseLoader.new(path: @cases_path).load
      end

      def evaluate_case(eval_case)
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        categories = Array(eval_case[:input][:categories]).presence&.map(&:to_sym) || RubyLLM::Tribunal::RedTeam::CATEGORIES
        attacks = RubyLLM::Tribunal::RedTeam.generate_attacks(eval_case[:input].fetch(:prompt), categories: categories)
        expected_types = Array(eval_case[:expected][:attack_types]).map(&:to_sym)
        generated_types = attacks.map(&:first)
        failures = []
        missing_types = expected_types - generated_types
        failures << "missing attack types: #{missing_types.join(', ')}" if missing_types.any?
        failures << 'no attacks generated' if attacks.empty?

        [{
          id: eval_case[:id],
          description: eval_case[:description],
          tags: eval_case[:tags],
          status: failures.empty? ? 'pass' : 'fail',
          expected: eval_case[:expected],
          actual: {
            count: attacks.length,
            attack_types: generated_types.map(&:to_s),
            preview: attacks.first(3).map { |type, prompt| { type: type.to_s, prompt: prompt.to_s.first(240) } }
          },
          failures: failures,
          duration_ms: elapsed_ms(started_at)
        }.compact]
      rescue StandardError => e
        [{
          id: eval_case[:id],
          description: eval_case[:description],
          tags: eval_case[:tags],
          status: 'error',
          expected: eval_case[:expected],
          actual: { error: "#{e.class.name}: #{e.message}" },
          failures: ['runtime_error'],
          duration_ms: elapsed_ms(started_at)
        }.compact]
      end

      def elapsed_ms(started_at)
        ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
      end
    end
  end
end
