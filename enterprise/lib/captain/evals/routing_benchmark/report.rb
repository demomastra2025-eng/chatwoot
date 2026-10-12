# frozen_string_literal: true

# The Markdown summary of a benchmark report, from the GATE verdict down to the triage list. It reads the report hash a
# run builds (symbol keys) or one loaded from JSON (string keys), so the same text can be rebuilt from an older output.
class Captain::Evals::RoutingBenchmark::Report
  DETAIL_LIMIT = 200
  TEXT_LIMIT = 500
  COVERAGE_ITEMS = {
    'a' => 'appointment expectations that name the doctor, the time and the service or patient (blocks the gate)',
    'b' => 'replies that claim a done action or a hand-over',
    'c' => 'turns that created, moved or cancelled an appointment',
    'd' => 'patient replies scanned for another patient\'s data',
    'e' => 'patient replies scanned for internal material',
    'f' => 'turns in which the customer asks for a person (blocks the gate)'
  }.freeze

  def initialize(report)
    @report = report.to_h.deep_stringify_keys
  end

  def markdown
    [header, gate_section, summary_section, triage_section].join("\n")
  end

  private

  def gate = @report.fetch('gate')

  def header = "# Routing benchmark\n"

  def gate_section
    critical, overall, triage = gate.values_at('critical', 'overall', 'triage')
    lines = ['## GATE', '', "**Verdict: #{gate['verdict']}**", '',
             '| Rule | Result |', '| --- | --- |',
             "| Critical checks, all must pass | #{critical['passed']}/#{critical['total']} passed (#{critical['pct']}%), #{critical['failed']} failed |",
             "| Overall score, at least #{overall['threshold']}% | #{overall['passed']}/#{overall['total']} turns passed (#{overall['pct']}%) |",
             "| Run complete | #{@report['aborted'] ? "no, stopped: #{@report['abort_reason']}" : 'yes'} |",
             "| Failed checks triaged by a person | #{triage['triaged']}/#{triage['failed_checks']} |"]
    lines += blockers_lines + after_triage_lines + coverage_lines + critical_failure_lines + check_table_lines
    "#{lines.join("\n")}\n"
  end

  # What the run put to the test: a critical check that no turn gives a chance to fail proves nothing.
  def coverage_lines
    coverage = gate['coverage']
    return [] unless coverage

    rows = COVERAGE_ITEMS.map do |item, what|
      entry = coverage[item] || {}
      expected = entry['expected'] ? "#{entry['covered']} of #{entry['expected']}" : entry['covered'].to_s
      "| #{item} | #{expected} | #{what} |"
    end
    ['', '### Coverage', '', '| Gate item | Covered | What counts |', '| --- | --- | --- |'] + rows
  end

  def blockers_lines
    return ['', 'No blockers.'] if gate['blockers'].blank?

    ['', 'Blockers:'] + gate['blockers'].map { |blocker| "- #{blocker}" }
  end

  def after_triage_lines
    after = gate['after_triage']
    return [] unless after

    ['', "After triage (test bugs and judge errors removed): **#{after['verdict']}**, critical failures #{after.dig('critical', 'failed')}, " \
         "overall #{after.dig('overall', 'pct')}%."]
  end

  def critical_failure_lines
    failures = gate.dig('critical', 'failures').to_a
    return ['', '### Critical failures', '', 'None.'] if failures.empty?

    ['', '### Critical failures', ''] + failures.map do |failure|
      line = "- `#{failure['dialogue']}` turn #{failure['turn']}#{run_suffix(failure)}: `#{failure['check']}` (gate #{failure['gate']})"
      failure['detail'].present? ? "#{line} #{cell(failure['detail'], DETAIL_LIMIT)}" : line
    end
  end

  def run_suffix(failure) = failure['run'].to_i > 1 ? " run #{failure['run']}" : ''

  def check_table_lines
    rows = gate['checks'].to_a.map do |name, stats|
      "| `#{name}` | #{stats['severity']} | #{stats['gate']} | #{stats['evaluated']} | #{stats['failed']} |"
    end
    return [] if rows.empty?

    ['', '### Checks', '', '| Check | Severity | Gate item | Evaluated (turns) | Failed |', '| --- | --- | --- | --- | --- |'] + rows
  end

  def summary_section
    agg = @report.fetch('aggregates')
    lines = ['## Summary', '',
             "Model: #{@report['model']}; runs: #{@report['runs']}; cases: #{agg['total']}; passed: #{agg['passed']}.",
             "Routing accuracy: #{agg['routing_accuracy']}; council detection: #{agg['council_detection']}.",
             "Council turns: #{agg['council_expected']}; event missing: #{agg['council_event_missing']}; unexpected: #{agg['council_unexpected']}.",
             "Passed when the council signal is ignored: #{agg['passed_ignoring_council_signal']}.",
             "Hard-zero counters: #{agg['hard_zero'].to_json}.",
             "Latency p50/p95: #{agg['latency_p50_ms']}/#{agg['latency_p95_ms']} ms.",
             "Estimated provider cost: $#{@report['cost_usd']}; budget reached: #{@report['aborted_at_budget']}."]
    lines += Array(@report['warnings']).map { |warning| "WARNING: #{warning}" }
    "#{lines.join("\n")}\n"
  end

  def triage_section
    records = @report.fetch('triage', [])
    lines = ['## TRIAGE', '',
             "#{records.size} failed check(s). Write agent_bug, test_bug or judge_error into the `triage` field of each record of the JSON " \
             'report and pass the file back as TRIAGE=<report.json>.', '']
    records.each_with_index { |record, index| lines.concat(record_lines(record, index + 1)) }
    "#{lines.join("\n")}\n"
  end

  def record_lines(record, number)
    [
      "### #{number}. #{record['severity']} - `#{record['dialogue']}` turn #{record['turn']}#{run_suffix(record)} - `#{record['check']}`",
      "- Fixture: #{record['fixture']}; acting agent: #{record['acting_agent']}; gate item: #{record['gate']}",
      "- Detail: #{record['detail'].present? ? cell(record['detail'], DETAIL_LIMIT) : 'none recorded'}",
      "- Patient: #{cell(record['patient_message'], TEXT_LIMIT)}",
      "- Agent reply: #{cell(record['agent_reply'], TEXT_LIMIT)}",
      "- Tool calls: #{tool_calls_text(record['tool_calls'])}",
      "- Database changes: #{delta_text(record['db_delta'])}",
      "- Expectation: #{record['expectation'] ? cell(record['expectation'].to_json, TEXT_LIMIT) : 'not recorded'}",
      "- Triage: #{record['triage'] || '________ (agent_bug | test_bug | judge_error)'}",
      ''
    ]
  end

  def tool_calls_text(calls)
    return 'none' if calls.blank?

    calls.map do |call|
      text = "#{call['tool']}#{call['success'] == false ? ' [failed]' : ''}"
      text += " args #{call['arguments']}" if call['arguments'].present?
      text += " -> #{call['result']}" if call['result'].present?
      text
    end.join('; ').squish.truncate(900)
  end

  # The appointment rows the turn changed: "appointment 12 created: doctor_b, consult, patient, 2026-10-15T12:00:00+05:00".
  def delta_text(delta)
    return 'none' if delta.blank?

    delta.map do |row|
      facts = row.values_at('resource', 'service', 'patient', 'starts_at').compact.join(', ')
      previous = row['previous']
      was = previous.present? ? " (was #{previous.values_at('resource', 'starts_at', 'status').compact.join(', ')})" : ''
      "appointment #{row['id']} #{row['change']}: #{facts}#{was}"
    end.join('; ').squish.truncate(TEXT_LIMIT)
  end

  def cell(value, limit) = value.to_s.squish.truncate(limit)
end
