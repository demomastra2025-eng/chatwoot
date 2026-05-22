# frozen_string_literal: true

class Captain::Evals::EventContractTraceSuite
  SUITE_ID = 'captain.event_contract_trace'
  DEFAULT_CASES_PATH = Rails.root.join('config/llm_evals/event_contract_trace.yml')
  FIXTURE_ROOT = Rails.root.join('config/llm_evals/fixtures/captain/event_contract')
  RAW_CONTENT_KEY_PATTERN = /\A(raw_)?(prompt|messages|input|output|response|content)\z/i

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
    events = load_events(eval_case.dig(:input, :fixture))
    actual = analyze(events)
    failures = compare(actual, eval_case)

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

  def load_events(fixture_path)
    path = fixture_file(fixture_path)
    JSON.parse(path.read).map { |event| event.to_h.deep_symbolize_keys }
  end

  def fixture_file(fixture_path)
    path = Rails.root.join(fixture_path.to_s).cleanpath
    root = FIXTURE_ROOT.cleanpath.to_s
    raise ArgumentError, 'invalid_fixture_path' unless path.to_s.start_with?("#{root}/")
    raise ArgumentError, 'missing_fixture' unless path.file?

    path
  end

  def analyze(events)
    payloads = events.map { |event| event.fetch(:payload, {}) }
    {
      event_names: events.pluck(:name),
      aliases: payloads.filter_map { |payload| payload[:event_name_alias] },
      project_case_ids: payloads.filter_map { |payload| payload[:project_case_id] }.uniq,
      tool_names: payloads.filter_map { |payload| payload[:tool_name] }.uniq,
      ui_action_types: ui_action_types(payloads),
      progress_event_count: events.count { |event| event[:name] == 'llm.tool.progress' },
      error_codes: payloads.filter_map { |payload| payload[:error_code] }.uniq,
      max_event_payload_bytes: payloads.map { |payload| payload.to_json.bytesize }.max.to_i,
      raw_content_keys: raw_content_keys(payloads),
      preview_keys: preview_keys(payloads),
      canonical_mismatches: canonical_mismatches(events),
      unsafe_ui_actions: unsafe_ui_actions(payloads)
    }
  end

  def compare(actual, eval_case)
    expected = eval_case.fetch(:expected, {}).deep_symbolize_keys
    failures = []

    Array(expected[:required_events]).each do |event_name|
      failures << "required event missing: #{event_name}" unless actual[:event_names].include?(event_name.to_s)
    end

    Array(expected[:required_tools]).each do |tool_name|
      failures << "required tool missing: #{tool_name}" unless actual[:tool_names].include?(tool_name.to_s)
    end

    Array(expected[:required_ui_actions]).each do |action_type|
      failures << "required ui_action missing: #{action_type}" unless actual[:ui_action_types].include?(action_type.to_s)
    end

    Array(expected[:required_aliases]).each do |event_alias|
      failures << "required event alias missing: #{event_alias}" unless actual[:aliases].include?(event_alias.to_s)
    end

    if expected[:required_error_code].present? && actual[:error_codes].exclude?(expected[:required_error_code].to_s)
      failures << "required error_code missing: #{expected[:required_error_code]}"
    end

    if expected[:required_progress_events].present? && actual[:progress_event_count] < expected[:required_progress_events].to_i
      failures << "required progress events missing: #{expected[:required_progress_events]}"
    end

    if actual[:project_case_ids] != [eval_case[:id]]
      failures << "project_case_id mismatch: expected #{eval_case[:id]}, got #{actual[:project_case_ids].inspect}"
    end

    max_payload_bytes = expected[:max_event_payload_bytes].to_i
    if max_payload_bytes.positive? && actual[:max_event_payload_bytes] > max_payload_bytes
      failures << "event payload exceeds budget: #{actual[:max_event_payload_bytes]} > #{max_payload_bytes}"
    end

    failures << "raw content keys present: #{actual[:raw_content_keys].join(', ')}" if actual[:raw_content_keys].present?
    failures << "raw preview keys present: #{actual[:preview_keys].join(', ')}" if actual[:preview_keys].present?
    failures << "canonical event mismatches: #{actual[:canonical_mismatches].join(', ')}" if actual[:canonical_mismatches].present?
    failures << "unsafe ui_actions present: #{actual[:unsafe_ui_actions].join(', ')}" if actual[:unsafe_ui_actions].present?

    failures
  end

  def ui_action_types(payloads)
    payloads.flat_map { |payload| Array(payload[:ui_actions]) }.filter_map do |action|
      action.to_h.deep_symbolize_keys[:type].presence
    end.uniq
  end

  def unsafe_ui_actions(payloads)
    payloads.flat_map { |payload| Array(payload[:ui_actions]) }.filter_map do |action|
      normalized = action.to_h.deep_stringify_keys
      extra_keys = normalized.keys - %w[type label target_id]
      next if extra_keys.empty? && Captain::UiActionContract.normalize([normalized]) == [normalized]

      "#{normalized['type'] || 'unknown'}:#{extra_keys.join('|')}"
    end
  end

  def raw_content_keys(values, prefix = nil)
    Array(values).flat_map do |value|
      case value
      when Hash
        value.flat_map do |key, child_value|
          path = [prefix, key].compact.join('.')
          matches = key.to_s.match?(RAW_CONTENT_KEY_PATTERN) ? [path] : []
          matches + raw_content_keys(child_value, path)
        end
      when Array
        value.flat_map.with_index { |child_value, index| raw_content_keys(child_value, [prefix, index].compact.join('.')) }
      else
        []
      end
    end
  end

  def preview_keys(values, prefix = nil)
    Array(values).flat_map do |value|
      case value
      when Hash
        value.flat_map do |key, child_value|
          path = [prefix, key].compact.join('.')
          matches = key.to_s.end_with?('_preview') ? [path] : []
          matches + preview_keys(child_value, path)
        end
      when Array
        value.flat_map.with_index { |child_value, index| preview_keys(child_value, [prefix, index].compact.join('.')) }
      else
        []
      end
    end
  end

  def canonical_mismatches(events)
    events.filter_map do |event|
      canonical = event.dig(:payload, :canonical_event_name)
      next if canonical == event[:name]

      "#{event[:name]}=>#{canonical || 'nil'}"
    end
  end

  def elapsed_ms(started_at)
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
  end
end
