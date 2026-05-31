# frozen_string_literal: true

class Captain::Evals::VoiceScenarioSuite
  SUITE_ID = 'captain.voice_scenarios'
  DEFAULT_CASES_PATH = Rails.root.join('config/llm_evals/voice_scenarios.yml')
  CLIP_MARKERS = [/pacer_drop/i, /truncated/i, /overflow/i, /audio_clipped/i].freeze

  def initialize(cases_path: DEFAULT_CASES_PATH)
    @cases_path = Pathname.new(cases_path)
  end

  def call
    Llm::Evals::Result.new(
      suite_id: SUITE_ID,
      prompt_id: nil,
      prompt_sha: nil,
      model: nil,
      cases: eval_cases.map { |eval_case| evaluate_case(eval_case) }
    )
  end

  private

  def eval_cases
    @eval_cases ||= Llm::Evals::CaseLoader.new(path: @cases_path).load
  end

  def evaluate_case(eval_case)
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    actual = actual_for(eval_case)
    failures = failures_for(eval_case.fetch(:expected, {}), actual)

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
    error_case_result(eval_case, e, started_at)
  end

  def actual_for(eval_case)
    events = Array(eval_case.dig(:input, :events)).map { |event| event.to_h.deep_symbolize_keys }
    {
      timeline: voice_timeline(events),
      latency: latency_summary(events),
      interruption_respected: interruption_respected?(events),
      transcript_fallback_used: transcript_fallback_used?(events),
      ai_response_after_last_caller: ai_response_after_last_caller?(events),
      clip_markers: clip_markers(events),
      tool_names: events.filter_map { |event| event[:tool_name].presence || event.dig(:payload, :tool_name).presence }.uniq
    }
  end

  def voice_timeline(events)
    events.map.with_index do |event, index|
      {
        index: index,
        action: event[:action],
        role: voice_role(event),
        transcript: event[:transcript].presence || event[:content].presence || event.dig(:payload, :transcript).presence,
        latency_ms: event[:latency_ms],
        ttfb_ms: event[:ttfb_ms],
        interrupted: truthy?(event[:interrupted]),
        fallback: event[:fallback]
      }.compact
    end
  end

  def latency_summary(events)
    latencies = events.filter_map { |event| integer_value(event[:latency_ms] || event[:ttfb_ms]) }.sort
    {
      count: latencies.size,
      p50_ms: percentile(latencies, 0.50),
      p95_ms: percentile(latencies, 0.95),
      max_ms: latencies.max
    }.compact
  end

  def failures_for(expected, actual)
    expected = expected.to_h.deep_symbolize_keys

    [
      ai_response_failure(expected, actual),
      interruption_failure(expected, actual),
      transcript_fallback_failure(expected, actual),
      latency_failure(expected, actual, expected_key: :max_ttfb_ms, actual_key: :max_ms, label: 'TTFB'),
      latency_failure(expected, actual, expected_key: :max_p95_latency_ms, actual_key: :p95_ms, label: 'p95 latency'),
      clip_marker_failure(expected, actual)
    ].compact
  end

  def ai_response_failure(expected, actual)
    return unless expected[:require_ai_response_after_last_caller] && !actual[:ai_response_after_last_caller]

    'ai response missing after last caller transcript'
  end

  def interruption_failure(expected, actual)
    return unless expected[:require_interruption_stop] && !actual[:interruption_respected]

    'voice interruption was not respected'
  end

  def transcript_fallback_failure(expected, actual)
    return unless expected[:require_transcript_fallback] && !actual[:transcript_fallback_used]

    'transcript fallback missing'
  end

  def latency_failure(expected, actual, expected_key:, actual_key:, label:)
    expected_value = expected[expected_key]
    actual_value = actual.dig(:latency, actual_key)
    return if expected_value.blank? || actual_value.to_i <= expected_value.to_i

    "#{label} too high: #{actual_value} > #{expected_value}"
  end

  def clip_marker_failure(expected, actual)
    return unless expected[:forbid_clip_markers] && actual[:clip_markers].present?

    "clip markers present: #{actual[:clip_markers].join(', ')}"
  end

  def interruption_respected?(events)
    interrupt_index = events.index { |event| event[:action].to_s.include?('interrupt') || truthy?(event[:interrupted]) }
    return true if interrupt_index.blank?

    events.drop(interrupt_index + 1).none? { |event| event[:action].to_s == 'realtime_audio_out' && !truthy?(event[:stopped]) }
  end

  def transcript_fallback_used?(events)
    events.any? { |event| event[:fallback].to_s == 'transcript' || event[:action].to_s.include?('transcript_fallback') }
  end

  def ai_response_after_last_caller?(events)
    last_caller_index = events.rindex { |event| voice_role(event) == 'caller' }
    return false if last_caller_index.blank?

    events.drop(last_caller_index + 1).any? { |event| voice_role(event) == 'assistant' }
  end

  def clip_markers(events)
    events.filter_map do |event|
      text = [event[:action], event[:status], event[:content], event[:transcript], event.dig(:payload, :error)].compact.join(' ')
      CLIP_MARKERS.find { |marker| text.match?(marker) }&.source
    end
  end

  def voice_role(event)
    role = event[:role].to_s
    return 'caller' if role.in?(%w[caller customer user]) || event[:action].to_s.include?('caller')
    return 'assistant' if role.in?(%w[assistant ai]) || event[:action].to_s.include?('ai_') || event[:action].to_s.include?('realtime_audio')

    nil
  end

  def percentile(values, percentile)
    return if values.blank?

    index = ((values.size - 1) * percentile).ceil
    values[index]
  end

  def integer_value(value)
    Integer(value) if value.present?
  rescue ArgumentError, TypeError
    nil
  end

  def truthy?(value)
    value == true || value.to_s == 'true'
  end

  def elapsed_ms(started_at)
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
  end

  def error_case_result(eval_case, error, started_at)
    {
      id: eval_case[:id],
      description: eval_case[:description],
      tags: eval_case[:tags],
      status: 'error',
      expected: eval_case[:expected],
      actual: { error: "#{error.class.name}: #{error.message}" },
      failures: ['runtime_error'],
      duration_ms: elapsed_ms(started_at)
    }.compact
  end
end
