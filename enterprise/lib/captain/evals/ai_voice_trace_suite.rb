# frozen_string_literal: true

class Captain::Evals::AiVoiceTraceSuite
  SUITE_ID = 'captain.ai_voice_trace'
  DEFAULT_CASES_PATH = Rails.root.join('config/llm_evals/ai_voice_trace.yml')

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
    actual = analyze(eval_case.dig(:input, :events))
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

  def analyze(raw_events)
    events = Array(raw_events).map { |event| event.to_h.deep_symbolize_keys }
    actions = events.filter_map { |event| event_action(event) }

    {
      actions: actions.tally,
      tool_events: tool_events(events),
      ai_text: ai_text(events)
    }
  end

  def compare(actual, expected)
    expected = expected.to_h.deep_symbolize_keys
    failures = []
    action_counts = actual.fetch(:actions, {})

    Array(expected[:require_actions]).each do |action|
      failures << "required action missing: #{action}" if action_counts[action.to_s].blank?
    end

    Array(expected[:forbid_actions]).each do |action|
      failures << "forbidden action present: #{action}" if action_counts[action.to_s].present?
    end

    Array(expected[:forbid_failed_tools]).each do |tool|
      failed = actual[:tool_events].any? { |event| event[:action] == 'tool_failed' && event[:tool_name] == tool.to_s }
      failures << "forbidden failed tool present: #{tool}" if failed
    end

    Array(expected[:require_tool_result_usage]).each do |requirement|
      requirement = requirement.to_h.deep_symbolize_keys
      next if tool_result_used?(actual[:tool_events], actual[:ai_text], requirement)

      failures << "tool result fragment was not used after #{requirement[:tool]}: #{requirement[:fragment]}"
    end

    failures
  end

  def tool_result_used?(tool_events, ai_text, requirement)
    fragment = requirement[:fragment].to_s
    return false if fragment.blank?

    completed_tool = tool_events.find do |event|
      event[:action] == 'tool_completed' &&
        event[:tool_name] == requirement[:tool].to_s &&
        event[:text].include?(fragment)
    end
    return false unless completed_tool

    ai_text.any? { |event| event[:index] > completed_tool[:index] && event[:text].include?(fragment) }
  end

  def event_action(event)
    (event[:action] || event[:event_type] || event.dig(:payload, :action) || event.dig(:payload, :payload, :action)).to_s.presence
  end

  def tool_events(events)
    events.map.with_index.filter_map do |event, index|
      action = event_action(event)
      next unless action&.start_with?('tool_')

      {
        index: index,
        action: action,
        tool_name: tool_name(event),
        text: event_text(event)
      }
    end
  end

  def ai_text(events)
    events.map.with_index.filter_map do |event, index|
      role = (event[:role] || event.dig(:payload, :role)).to_s
      action = event_action(event).to_s
      text = event_text(event)
      next if text.blank?
      next unless role == 'ai' || role == 'assistant' || action.include?('ai_transcript') || action.include?('realtime_audio_out')

      { index: index, text: text }
    end
  end

  def tool_name(event)
    (event[:tool_name] || event[:name] || event.dig(:payload, :tool_name) || event.dig(:payload, :name) ||
      event.dig(:payload, :payload, :tool_name)).to_s
  end

  def event_text(event)
    values = [
      event[:content],
      event[:text],
      event[:transcript],
      event[:reason],
      event[:result],
      event.dig(:payload, :content),
      event.dig(:payload, :text),
      event.dig(:payload, :transcript),
      event.dig(:payload, :result),
      event.dig(:payload, :payload, :content),
      event.dig(:payload, :payload, :result)
    ]

    values.compact.map { |value| value.is_a?(String) ? value : value.to_json }.join(' ')
  end

  def elapsed_ms(started_at)
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
  end
end
