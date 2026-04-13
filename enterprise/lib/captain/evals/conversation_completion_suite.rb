# frozen_string_literal: true

require 'digest'

module Captain
  module Evals
    class ConversationCompletionSuite
      SUITE_ID = 'captain.conversation_completion'.freeze
      PROMPT_ID = 'conversation_completion'.freeze
      DEFAULT_CASES_PATH = Rails.root.join('config/llm_evals/conversation_completion.yml')

      def initialize(account:, cases_path: DEFAULT_CASES_PATH, model: nil, runner: nil)
        @account = account
        @cases_path = cases_path
        @model = model
        @runner = runner || method(:run_case_via_runtime)
      end

      def call
        report_cases = eval_cases.map do |eval_case|
          evaluate_case(eval_case)
        end

        ::Llm::Evals::Result.new(
          suite_id: SUITE_ID,
          prompt_id: PROMPT_ID,
          prompt_sha: prompt_sha,
          model: resolved_model,
          cases: report_cases
        )
      end

      private

      def eval_cases
        @eval_cases ||= ::Llm::Evals::CaseLoader.new(path: @cases_path).load
      end

      def evaluate_case(eval_case)
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        actual = @runner.call(messages: eval_case.dig(:input, :messages), model: resolved_model)
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

      def compare(actual, expected)
        failures = []
        expected = expected.deep_symbolize_keys
        actual = actual.to_h.deep_symbolize_keys

        if expected.key?(:complete) && actual[:complete] != expected[:complete]
          failures << "expected complete=#{expected[:complete].inspect}, got #{actual[:complete].inspect}"
        end

        Array(expected[:reason_includes]).each do |fragment|
          next if actual[:reason].to_s.downcase.include?(fragment.to_s.downcase)

          failures << "reason missing fragment: #{fragment}"
        end

        failures
      end

      def elapsed_ms(started_at)
        ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
      end

      def resolved_model
        @resolved_model ||= @model.presence || ::Llm::Config.model_for(
          feature: 'assistant',
          account: @account,
          fallback: Captain::BaseTaskService::GPT_MODEL
        )
      end

      def prompt_sha
        @prompt_sha ||= Digest::SHA256.hexdigest(Captain::PromptRegistry.fetch_task!(PROMPT_ID))
      end

      def run_case_via_runtime(messages:, model:)
        Captain::ConversationCompletionEvaluator.new(
          account: @account,
          conversation_display_id: nil,
          messages: messages,
          model: model
        ).perform
      end
    end
  end
end
