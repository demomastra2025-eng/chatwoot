# frozen_string_literal: true

module Llm
  module Evals
    class Result
      attr_reader :suite_id, :prompt_id, :prompt_sha, :model, :generated_at, :cases

      def initialize(suite_id:, prompt_id:, prompt_sha:, model:, cases:, generated_at: Time.current)
        @suite_id = suite_id
        @prompt_id = prompt_id
        @prompt_sha = prompt_sha
        @model = model
        @cases = Array(cases)
        @generated_at = generated_at
      end

      def total_count
        cases.size
      end

      def passed_count
        cases.count { |result| result[:status] == 'pass' }
      end

      def failed_count
        cases.count { |result| result[:status] == 'fail' }
      end

      def error_count
        cases.count { |result| result[:status] == 'error' }
      end

      def pass_rate
        return 0.0 if total_count.zero?

        (passed_count.to_f / total_count).round(4)
      end

      def passed?
        failed_count.zero? && error_count.zero?
      end

      def status
        passed? ? 'pass' : 'fail'
      end

      def to_h
        {
          suite_id: suite_id,
          status: status,
          prompt_id: prompt_id,
          prompt_sha: prompt_sha,
          model: model,
          generated_at: generated_at,
          total_count: total_count,
          passed_count: passed_count,
          failed_count: failed_count,
          error_count: error_count,
          pass_rate: pass_rate,
          cases: cases
        }
      end
    end
  end
end
