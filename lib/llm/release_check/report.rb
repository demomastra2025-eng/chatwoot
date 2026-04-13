# frozen_string_literal: true

module Llm
  module ReleaseCheck
    class Report
      PASSING_STATUSES = %w[pass pass_with_warnings].freeze
      WARNING_STATUSES = %w[disabled insufficient_data not_applicable].freeze

      attr_reader :generated_at, :account_id, :date_range, :filters, :operational, :evals, :checks

      def initialize(generated_at:, account_id:, date_range:, filters:, operational:, evals:, checks:)
        @generated_at = generated_at
        @account_id = account_id
        @date_range = date_range
        @filters = filters.to_h.deep_symbolize_keys
        @operational = operational.deep_symbolize_keys
        @evals = evals.deep_symbolize_keys
        @checks = Array(checks).map { |check| check.deep_symbolize_keys }
      end

      def passed?
        PASSING_STATUSES.include?(status)
      end

      def blocking_failures
        checks.select { |check| check[:blocking] }
      end

      def status
        return 'fail' if blocking_failures.any?
        return 'pass_with_warnings' if checks.any? { |check| WARNING_STATUSES.include?(check[:status].to_s) }

        'pass'
      end

      def to_h
        {
          generated_at: generated_at,
          status: status,
          account_id: account_id,
          date_range: serialize_date_range,
          filters: filters.presence,
          blocking_failures: blocking_failures,
          operational: operational,
          evals: evals,
          checks: checks
        }.compact
      end

      private

      def serialize_date_range
        return if date_range.blank?

        {
          since: date_range.begin,
          until: date_range.end
        }
      end
    end
  end
end
