# frozen_string_literal: true

class Captain::Evals::KnowledgeRagTraceSuite
  SUITE_ID = 'captain.knowledge_rag_trace'
  DEFAULT_CASES_PATH = Rails.root.join('config/llm_evals/knowledge_rag_trace.yml')

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
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    actual = analyze(eval_case.dig(:input, :result))
    failures = compare(actual, eval_case.fetch(:expected, {}))

    case_result(eval_case, actual, failures, elapsed_ms(started_at))
  rescue StandardError => e
    case_result(eval_case, { error: "#{e.class.name}: #{e.message}" }, ['runtime_error'], elapsed_ms(started_at), status: 'error')
  end

  def case_result(eval_case, actual, failures, duration_ms, status: nil)
    {
      id: eval_case[:id],
      description: eval_case[:description],
      tags: eval_case[:tags],
      status: status || (failures.empty? ? 'pass' : 'fail'),
      expected: eval_case[:expected],
      actual: actual,
      failures: failures,
      duration_ms: duration_ms
    }.compact
  end

  def analyze(result)
    payload = result.to_h.deep_symbolize_keys
    trace = payload.fetch(:retrieval_trace, {}).to_h.deep_symbolize_keys
    matches = Array(payload[:matches]).map { |match| match.to_h.deep_symbolize_keys }

    trace_summary(payload, trace, matches).merge(trace_ids_summary(trace, matches))
  end

  def trace_summary(payload, trace, matches)
    {
      lookup_strategy: payload[:lookup_strategy].presence || trace[:strategy],
      trace_strategy: trace[:strategy],
      degraded: trace[:degraded],
      semantic_attempted: trace[:semantic_attempted],
      fallback_reason: trace[:fallback_reason].to_s.presence,
      match_count: trace[:match_count] || matches.size,
      match_types: matches.filter_map { |match| match[:type] }.uniq,
      embedding_status_counts: trace.fetch(:embedding_status_counts, {}).to_h.deep_symbolize_keys
    }
  end

  def trace_ids_summary(trace, matches)
    {
      document_chunk_ids: trace_ids(trace[:document_chunk_ids], matches, :document_chunk_id),
      document_ids: trace_ids(trace[:document_ids], matches, :document_id),
      response_ids: trace_ids(trace[:response_ids], matches, :id)
    }
  end

  def compare(actual, expected)
    expected = expected.to_h.deep_symbolize_keys
    failures = []

    compare_strategy(actual, expected, failures)
    compare_boolean(:degraded, actual, expected, failures)
    compare_boolean(:semantic_attempted, actual, expected, failures)
    compare_fallback_reason(actual, expected, failures)
    compare_match_count(actual, expected, failures)
    compare_required_ids(actual, expected, failures)
    compare_indexed_chunks(actual, expected, failures)
    compare_lexical_success(actual, expected, failures)

    failures
  end

  def compare_strategy(actual, expected, failures)
    return if expected[:strategy].blank?

    expected_strategy = expected[:strategy].to_s
    append_mismatch(failures, 'lookup_strategy', expected_strategy, actual[:lookup_strategy])
    append_mismatch(failures, 'trace strategy', expected_strategy, actual[:trace_strategy])
  end

  def append_mismatch(failures, label, expected, actual)
    return if actual == expected

    failures << "#{label} mismatch: expected #{expected}, got #{actual}"
  end

  def compare_boolean(field, actual, expected, failures)
    return unless expected.key?(field)
    return if actual[field] == expected[field]

    failures << "#{field} mismatch: expected #{expected[field]}, got #{actual[field].inspect}"
  end

  def compare_fallback_reason(actual, expected, failures)
    return if expected[:fallback_reason].blank?
    return if actual[:fallback_reason] == expected[:fallback_reason].to_s

    failures << "fallback_reason mismatch: expected #{expected[:fallback_reason]}, got #{actual[:fallback_reason]}"
  end

  def compare_match_count(actual, expected, failures)
    min_match_count = expected[:min_match_count].to_i
    return unless min_match_count.positive?
    return if actual[:match_count].to_i >= min_match_count

    failures << "match_count too low: #{actual[:match_count]} < #{min_match_count}"
  end

  def compare_required_ids(actual, expected, failures)
    {
      require_document_chunk_ids: :document_chunk_ids,
      require_document_ids: :document_ids,
      require_response_ids: :response_ids
    }.each do |flag, field|
      failures << "#{field} missing" if expected[flag] && actual[field].blank?
    end
  end

  def compare_indexed_chunks(actual, expected, failures)
    return unless expected[:require_indexed_chunks]
    return if actual.dig(:embedding_status_counts, :indexed).to_i.positive?

    failures << 'indexed chunk count missing'
  end

  def compare_lexical_success(actual, expected, failures)
    return unless expected[:forbid_lexical_success]
    return unless actual[:lookup_strategy] == 'lexical' && actual[:degraded] != true

    failures << 'semantic success degraded to lexical'
  end

  def trace_ids(trace_values, matches, match_key)
    ids = Array(trace_values).presence || matches.filter_map { |match| match[match_key] }
    ids.map(&:to_s).uniq
  end

  def elapsed_ms(started_at)
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
  end
end
