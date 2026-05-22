# frozen_string_literal: true

require 'ruby_llm/tribunal'

module Llm
  module Evals
    class TribunalDatasetRunner
      DEFAULT_DATASET_ROOTS = [
        Rails.root.join('config/llm_evals/datasets'),
        Rails.root.join('spec/llm_evals/datasets')
      ].freeze
      DEFAULT_PATTERNS = DEFAULT_DATASET_ROOTS.flat_map do |root|
        %w[json yaml yml].map { |extension| root.join("**/*.#{extension}").to_s }
      end.freeze
      MAX_CONCURRENCY = 8

      attr_reader :files, :provider, :strict, :threshold

      def initialize(files: nil, provider: nil, strict: false, threshold: nil, concurrency: 1, allow_live_assertions: false, max_cases: nil)
        @files = normalize_files(files)
        @provider = provider
        @strict = ActiveModel::Type::Boolean.new.cast(strict)
        @threshold = threshold&.to_f
        @concurrency = [[concurrency.to_i, 1].max, MAX_CONCURRENCY].min
        @allow_live_assertions = ActiveModel::Type::Boolean.new.cast(allow_live_assertions)
        @max_cases = normalize_max_cases(max_cases)
        @max_cases ||= Llm::Evals::RunRequest::DEFAULT_MAX_CASES if @allow_live_assertions
      end

      def call
        Llm::Evals::TribunalConfig.apply!
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
        cases = run_case_entries(case_entries)
        aggregate(cases, started_at)
      end

      def format(result, format: :console)
        RubyLLM::Tribunal::Reporter.format(result, format.to_sym)
      end

      def estimated_live_assertion_count
        case_entries.sum do |raw_case, _path, _index|
          payload = raw_case.to_h.deep_symbolize_keys
          live_assertion_types(assertion_types(normalize_assertions(payload))).size
        end
      end

      private

      def normalize_files(raw_files)
        explicit = Array(raw_files).flat_map { |value| value.to_s.split(',') }.filter_map { |value| value.strip.presence }
        files = explicit.presence || DEFAULT_PATTERNS.flat_map { |pattern| Dir.glob(pattern) }
        files.map { |path| Rails.root.join(path).cleanpath.to_s }.uniq
      end

      def normalize_max_cases(value)
        normalized = value.to_i
        normalized.positive? ? normalized : nil
      end

      def case_entries
        entries = files.flat_map do |path|
          load_cases(path).each_with_index.map { |entry, index| [entry, path, index] }
        end
        return entries unless @allow_live_assertions && @max_cases.present?

        entries.first(@max_cases)
      end

      def run_case_entries(entries)
        return entries.map { |entry, path, index| run_case(entry, path, index) } if @concurrency <= 1 || entries.one?

        queue = Queue.new
        entries.each_with_index { |entry, result_index| queue << [entry, result_index] }
        results = Array.new(entries.length)

        [@concurrency, entries.length].min.times.map do
          Thread.new do
            loop do
              (entry, path, case_index), result_index = queue.pop(true)
              results[result_index] = with_connection { run_case(entry, path, case_index) }
            rescue ThreadError
              break
            end
          end
        end.each(&:join)

        results
      end

      def load_cases(path)
        content = File.read(path)
        parsed = case File.extname(path).downcase
                 when '.json'
                   JSON.parse(content)
                 when '.yaml', '.yml'
                   YAML.safe_load(content, aliases: true, permitted_classes: [Symbol])
                 else
                   raise ArgumentError, "Unsupported eval dataset format: #{path}"
                 end

        Array(parsed.is_a?(Hash) ? parsed.fetch('cases', []) : parsed)
      end

      def run_case(raw_case, path, index = nil)
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
        payload = raw_case.to_h.deep_symbolize_keys
        test_case = build_test_case(payload)
        test_case = test_case.with_output(provider_output(test_case, payload)) if provider.present?
        assertions = normalize_assertions(payload)
        types = assertion_types(assertions)
        return failed_case(raw_case, path, index, :missing_assertions, 'at least one assertion is required') if types.blank?
        return failed_case(raw_case, path, index, :missing_actual_output, 'actual_output is required when provider is not configured') if test_case.actual_output.blank?

        blocked_types = live_assertion_types(types)
        if blocked_types.any? && !@allow_live_assertions
          return failed_case(raw_case, path, index, :live_assertions_blocked, "live assertions require explicit acknowledgement: #{blocked_types.join(', ')}")
        end

        results = RubyLLM::Tribunal.evaluate(test_case, assertions)
        failures = result_failures(results)

        {
          file: relative_path(path),
          id: payload[:id].presence || Digest::SHA1.hexdigest(test_case.input.to_s).first(12),
          index: index,
          input: test_case.input,
          status: failures.empty? ? :passed : :failed,
          failures: failures,
          results: results,
          duration_ms: elapsed_ms(started_at)
        }
      rescue StandardError => e
        {
          file: relative_path(path),
          id: raw_case.to_h['id'] || raw_case.to_h[:id],
          index: index,
          input: raw_case.to_h['input'] || raw_case.to_h[:input],
          status: :failed,
          failures: [[:runtime_error, sanitized_error(e)]],
          results: {},
          duration_ms: elapsed_ms(started_at)
        }.compact
      end

      def failed_case(raw_case, path, index, type, reason)
        {
          file: relative_path(path),
          id: raw_case.to_h['id'] || raw_case.to_h[:id],
          index: index,
          input: raw_case.to_h['input'] || raw_case.to_h[:input],
          status: :failed,
          failures: [[type, reason]],
          results: {},
          duration_ms: 0
        }.compact
      end

      def build_test_case(payload)
        RubyLLM::Tribunal.test_case(
          input: payload.fetch(:input),
          actual_output: payload[:actual_output] || payload[:output],
          expected_output: expected_output(payload),
          context: payload[:context],
          retrieval_context: payload[:retrieval_context],
          metadata: payload[:metadata]
        )
      end

      def normalize_assertions(payload)
        assertions = payload[:assertions] || payload.dig(:expected, :assertions)
        return assertions if assertions.present?

        expected = payload[:expected]
        return {} unless expected.is_a?(Hash)

        expected.except(:output, :actual_output, :expected_output, :assertions)
      end

      def expected_output(payload)
        return payload[:expected_output] if payload.key?(:expected_output)
        return payload.dig(:expected, :expected_output) if payload[:expected].is_a?(Hash) && payload.dig(:expected, :expected_output).present?
        return payload.dig(:expected, :output) if payload[:expected].is_a?(Hash) && payload.dig(:expected, :output).present?

        payload[:expected] unless payload[:expected].is_a?(Hash)
      end

      def assertion_types(assertions)
        case assertions
        when Hash
          assertions.keys.map(&:to_sym)
        when Array
          assertions.flat_map do |item|
            case item
            when Symbol, String
              item.to_sym
            when Array
              item.first.to_sym
            when Hash
              item.keys.map(&:to_sym)
            end
          end.compact
        else
          []
        end
      end

      def live_assertion_types(types)
        live_types = RubyLLM::Tribunal.judge_names + [:similar]
        types & live_types
      end

      def provider_output(test_case, payload)
        klass_name, method_name = provider.to_s.split(':', 2)
        raise ArgumentError, 'Provider must use ClassName:method format' if klass_name.blank? || method_name.blank?

        klass_name.constantize.public_send(method_name, test_case, payload)
      end

      def result_failures(results)
        results.filter_map do |type, result|
          status, details = result
          next if status == :pass

          [type, failure_reason(details)]
        end
      end

      def failure_reason(details)
        return details if details.is_a?(String)
        return details[:reason] if details.is_a?(Hash) && details[:reason].present?

        details.inspect
      end

      def aggregate(cases, started_at)
        duration = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond) - started_at
        passed = cases.count { |entry| entry[:status] == :passed }
        failed = cases.count { |entry| entry[:status] == :failed }
        total = cases.length
        summary = {
          total: total,
          passed: passed,
          failed: failed,
          pass_rate: total.positive? ? passed.to_f / total : 0.0,
          duration_ms: duration,
          strict: strict,
          threshold: threshold,
          threshold_passed: threshold_passed?(passed, failed, total)
        }

        {
          summary: summary,
          metrics: aggregate_metrics(cases),
          cases: cases
        }
      end

      def aggregate_metrics(cases)
        cases.flat_map { |entry| entry[:results].map { |type, result| [type, result.first == :pass] } }
             .group_by(&:first)
             .transform_values do |entries|
               { passed: entries.count { |_type, passed| passed }, total: entries.length }
             end
      end

      def threshold_passed?(passed, failed, total)
        return failed.zero? if strict
        return true if threshold.blank?
        return false if total.zero?

        (passed.to_f / total) >= threshold
      end

      def elapsed_ms(started_at)
        (Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond) - started_at).round
      end

      def relative_path(path)
        Pathname.new(path).relative_path_from(Rails.root).to_s
      rescue ArgumentError
        path.to_s
      end

      def with_connection(&)
        return yield unless defined?(ActiveRecord::Base)

        ActiveRecord::Base.connection_pool.with_connection(&)
      end

      def sanitized_error(error)
        "#{error.class.name}: #{error.message}".gsub(/(api[_-]?key|token|secret|password|authorization|credential)(=|:)?[^\s,;&]*/i) do |match|
          "#{match.split(/=|:/, 2).first}=[REDACTED]"
        end
      end
    end
  end
end
