# frozen_string_literal: true

module Llm
  module Evals
    class CollectionResult
      attr_reader :suites, :generated_at

      def initialize(suites:, generated_at: Time.current)
        @suites = Array(suites)
        @generated_at = generated_at
      end

      def suite_count
        suites.size
      end

      def total_count
        suites.sum(&:total_count)
      end

      def passed_count
        suites.sum(&:passed_count)
      end

      def failed_count
        suites.sum(&:failed_count)
      end

      def error_count
        suites.sum(&:error_count)
      end

      def passed?
        suites.all?(&:passed?)
      end

      def status
        passed? ? 'pass' : 'fail'
      end

      def to_h
        {
          status: status,
          generated_at: generated_at,
          suite_count: suite_count,
          total_count: total_count,
          passed_count: passed_count,
          failed_count: failed_count,
          error_count: error_count,
          suites: suites.map(&:to_h)
        }
      end
    end
  end
end
