# frozen_string_literal: true

# The Markdown summary of a benchmark report, from the GATE verdict down to the triage list. It reads the report hash a
# run builds (symbol keys) or one loaded from JSON (string keys), so the same text can be rebuilt from an older output.
class Captain::Evals::RoutingBenchmark::Report
  DETAIL_LIMIT = 200
  TEXT_LIMIT = 500
  FAILED_DIALOGUE_LIMIT = 40
  COVERAGE_ITEMS = {
    'a' => 'appointment expectations that pin the start time (blocks the gate)',
    'b' => 'replies that claim a done action or a hand-over',
    'c' => 'turns that created, moved or cancelled an appointment',
    'd' => 'patient replies scanned for another patient\'s data',
    'e' => 'patient replies scanned for internal material',
    'f' => 'turns in which the customer asks for a person (blocks the gate)'
  }.freeze

  def initialize(report)
    @report = report.to_h.deep_stringify_keys
  end

  REVIEW_LIMIT = 150

  def markdown
    [header, gate_section, summary_section, dialogues_section, triage_section, review_section].reject(&:empty?).join("\n")
  end

  private

  def gate = @report.fetch('gate')

  def header = "# Routing benchmark\n"

  def gate_section
    critical, overall, triage = gate.values_at('critical', 'overall', 'triage')
    pass_k = overall['runs'].to_i > 1 ? "pass^#{overall['runs']}: a turn passes only when it passes in every run; " : ''
    lines = ['## GATE', '', "**Verdict: #{gate['verdict']}**", '',
             '| Rule | Result |', '| --- | --- |',
             "| Critical checks, all must pass | #{critical['passed']}/#{critical['total']} passed (#{critical['pct']}%), #{critical['failed']} failed |",
             "| Overall score, at least #{overall['threshold']}% (#{pass_k}turns not evaluated are left out) | " \
             "#{overall['passed']}/#{overall['total']} turns passed (#{overall['pct']}%) |"]
    lines << unblocked_row(gate['overall_unblocked'], overall) if overall['blocked_turns'].to_i.positive?
    lines << "| Turns not evaluated (no verdict of the rubric judge) | #{not_evaluated_cell} |" if gate['not_evaluated']
    lines += ["| Run complete | #{@report['aborted'] ? "no, stopped: #{@report['abort_reason']}" : 'yes'} |",
              "| Failed checks triaged by a person | #{triage['triaged']}/#{triage['failed_checks']} |"]
    lines << "| Rubric judge | #{judge_cell} |" unless gate['judge'].nil?
    lines << "| Handoff is silent (blank notice) | #{silent_cell} |" if silent_cell
    lines += run_lines + dialogue_lines + hint_lines + infra_lines
    lines += blockers_lines + after_triage_lines + coverage_lines + critical_failure_lines + check_table_lines
    "#{lines.join("\n")}\n"
  end

  def not_evaluated_cell
    left = gate['not_evaluated']
    left['turns'].to_i.positive? ? "#{left['turns']} #{left['by_check'].to_json}" : 'none'
  end

  def judge_cell = gate['judge'] ? 'on' : 'off: the text of the replies is not evaluated'

  # The score of each run on its own (with RUNS=3 three rows): the per-turn pass rate, the critical failures, the critical hints.
  def run_lines
    runs = gate['runs'].to_h
    return [] if runs.empty?

    rows = runs.map do |run, stats|
      "| #{run} | #{stats['passed']}/#{stats['passed'].to_i + stats['failed'].to_i} (#{stats['pct']}%) | #{stats['not_evaluated']} | " \
        "#{stats['critical_failures']} | #{stats['hints']} (#{stats['critical_hints']} critical) |"
    end
    ['', '### Runs', '', '| Run | Turns passed | Not evaluated | Critical failures | Hints (detectors, never failures) |', '| --- | --- | --- | --- | --- |'] + rows
  end

  # pass^k of the dialogues: passed in every run.
  def dialogue_lines
    dialogues = gate['dialogues']
    return [] unless dialogues

    ['', "Dialogues: pass^#{dialogues['runs']} #{dialogues['passed_every_run']}/#{dialogues['total']} (#{dialogues['pass_k_pct']}%), " \
         "failed #{dialogues['failed']}, not evaluated #{dialogues['not_evaluated']}."]
  end

  # The hits of the checks that read text: they never fail a turn; the list of the critical ones to read is in NEEDS REVIEW.
  def hint_lines
    hints = gate['hints']
    return [] unless hints && hints['total'].to_i.positive?

    by_check = hints['by_check'].map { |name, row| "`#{name}` #{row['turns']} (#{row['severity']})" }.join(', ')
    ['', "Detector hints (they never fail a turn or the gate): #{hints['total']}, critical #{hints['critical']}; #{by_check}. See NEEDS REVIEW."]
  end

  # The turns the runner played on a conversation that staff owned and nobody had given back cannot happen live: the verdict counts them,
  # and the score without them is shown next to it.
  def unblocked_row(unblocked, overall)
    unblocked = unblocked.to_h
    "| Overall score without the #{overall['blocked_turns']} blocked turn(s) (information) | " \
      "#{unblocked['passed']}/#{unblocked['total']} turns passed (#{unblocked['pct']}%) |"
  end

  # "yes" / "no" when the run checked that the notice is blank, "not proven: <error>" when it could not read it, else nothing.
  def silent_cell
    return (gate['silent_handoff'] ? 'yes' : 'no') unless gate['silent_handoff'].nil?

    "not proven: #{gate['silent_handoff_error']}" if gate['silent_handoff_error']
  end

  # Turns that failed because of the infrastructure under the agents (a technical handoff, a provider error): counted as failed
  # turns above, and kept apart from the quality rates of the summary.
  def infra_lines
    infra = gate['infra']
    return [] unless infra && infra['turns'].to_i.positive?

    ['', "Infrastructure failures (left out of the quality rates, still failed turns): #{infra['turns']} turn(s), #{infra['by_check'].to_json}."]
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
             "Model: #{@report['model']}; runs: #{@report['runs']}; cases: #{agg['total']}; passed: #{agg['passed']}; " \
             "not evaluated: #{agg['not_evaluated'].to_i}.",
             "Routing accuracy: #{agg['routing_accuracy']}; council detection: #{agg['council_detection']}.",
             "Council turns: #{agg['council_expected']}; event missing: #{agg['council_event_missing']}; unexpected: #{agg['council_unexpected']}.",
             "Passed when the council signal is ignored: #{agg['passed_ignoring_council_signal']}.",
             "Hard-zero counters (duplicates and wrong patients are facts; the claim, leak and language counters count detector hints): " \
             "#{agg['hard_zero'].to_json}.",
             "Latency p50/p95: #{agg['latency_p50_ms']}/#{agg['latency_p95_ms']} ms.",
             "Estimated provider cost: $#{@report['cost_usd']}; budget reached: #{@report['aborted_at_budget']}."]
    lines += quality_lines(agg)
    lines += Array(@report['warnings']).map { |warning| "WARNING: #{warning}" }
    "#{lines.join("\n")}\n"
  end

  # The accuracies over the turns that state the expectation and ran to their end, and the dialogue totals.
  def quality_lines(agg)
    return [] unless agg['dialogues']

    dialogues = agg['dialogues']
    pass_k = dialogues['pass_k'].to_h
    rate = ->(key) { agg[key].nil? ? 'n/a' : agg[key] }
    lines = ["Accuracy without infrastructure failures: routing #{rate.call('routing_accuracy')}, transfers #{rate.call('transfer_accuracy')}, " \
             "staff handoff #{rate.call('staff_handoff_accuracy')}, acts #{rate.call('acts_accuracy')}.",
             "Dialogues: #{dialogues['passed']}/#{dialogues['total']} passed on every turn, #{dialogues['not_evaluated'].to_i} not evaluated; " \
             "blocked turns: #{dialogues['blocked_turns']}; " \
             "pass^#{pass_k['k']}: #{pass_k['passed_every_run']}/#{pass_k['dialogues']} (#{pass_k['rate']}), #{pass_k['not_evaluated'].to_i} not evaluated."]
    infra = agg['infra'].to_h
    lines << "Infrastructure failures: #{infra['turns']} turn(s) #{infra['by_check'].to_json}." if infra['turns'].to_i.positive?
    judge = agg['judge_unusable'].to_h
    if judge['turns'].to_i.positive?
      lines << "Rubric judge without a verdict (no failure of the turn, but the turn is not evaluated): #{judge['turns']} turn(s) #{judge['by_check'].to_json}."
    end
    lines
  end

  # The categories, the failed checks by reason and the dialogues that did not pass, turn by turn.
  def dialogues_section
    agg = @report['aggregates'].to_h
    return '' if agg['by_category'].blank?

    lines = ['## Dialogues', '', '| Category | Dialogues passed | Turns passed |', '| --- | --- | --- |']
    agg['by_category'].each do |category, stats|
      lines << "| #{category} | #{stats['dialogues_passed']}/#{stats['dialogues']} | #{stats['turns_passed']}/#{stats['turns']} |"
    end
    lines += reason_lines(agg['by_reason']) + failed_dialogue_lines
    "#{lines.join("\n")}\n"
  end

  def reason_lines(by_reason)
    return [] if by_reason.blank?

    ['', 'Failed turns by check: ' + by_reason.map { |check, count| "`#{check}` #{count}" }.join(', ') + '.']
  end

  # "council_two_part_03 run 1: t1 pass, t2 FAIL (wrong_agent), t3 blocked": a turn after a failed turn that the later turns build on is
  # shown as blocked, not as a finding of its own.
  def failed_dialogue_lines
    failed = Array(@report['dialogue_summaries']).reject { |item| item['pass'] }
    return [] if failed.empty?

    lines = ['', "Dialogues that did not pass (#{failed.size}; blocked = failed after an earlier failure it depends on):"]
    failed.first(FAILED_DIALOGUE_LIMIT).each do |item|
      numbers = item['turn_numbers'] || item['statuses'].each_index.map { |index| index + 1 }
      turns = item['statuses'].each_with_index.map { |status, index| "t#{numbers[index]} #{{ 'fail' => 'FAIL', 'not_evaluated' => 'not evaluated' }.fetch(status, status)}" }
      first = item['first_failure'].to_h
      detail = first['checks'].present? ? " (first failure: turn #{first['turn']}, #{first['checks'].join(', ')})" : ''
      lines << "- `#{item['dialogue']}`#{run_suffix(item)}: #{turns.join(', ')}#{detail}"
    end
    lines << "- ... and #{failed.size - FAILED_DIALOGUE_LIMIT} more" if failed.size > FAILED_DIALOGUE_LIMIT
    lines
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
      *coordination_lines(record),
      "- Database changes: #{delta_text(record['db_delta'])}",
      "- Expectation: #{record['expectation'] ? cell(record['expectation'].to_json, TEXT_LIMIT) : 'not recorded'}",
      "- Triage: #{record['triage'] || '________ (agent_bug | test_bug | judge_error)'}",
      ''
    ]
  end

  # The hits of the checks that read text, critical first, for a person: each shows what the detector found, the reply, and the verdict of
  # the rubric judge, which saw the hit and decided by meaning.
  def review_section
    records = Array(@report['needs_review'])
    return '' if records.empty?

    critical = records.count { |record| record['severity'] == 'critical' }
    lines = ['## NEEDS REVIEW', '',
             "#{records.size} detector hint(s), #{critical} critical. A detector of text never fails a turn or the gate; read the critical hints first " \
             'and decide whether the reply has the fault.', '']
    records.first(REVIEW_LIMIT).each_with_index { |record, index| lines.concat(review_lines(record, index + 1)) }
    lines << "... and #{records.size - REVIEW_LIMIT} more (all of them are in `needs_review` of the JSON report)." if records.size > REVIEW_LIMIT
    "#{lines.join("\n")}\n"
  end

  def review_lines(record, number)
    [
      "### #{number}. #{record['severity']} - `#{record['dialogue']}` turn #{record['turn']}#{run_suffix(record)} - `#{record['check']}`",
      "- Detail: #{record['detail'].present? ? cell(record['detail'], DETAIL_LIMIT) : 'none recorded'}",
      "- Patient: #{cell(record['patient_message'], TEXT_LIMIT)}",
      "- Agent reply: #{cell(record['agent_reply'], TEXT_LIMIT)}",
      "- Rubric judge: #{judge_text(record['judge'])}",
      ''
    ]
  end

  def judge_text(judge)
    judge = judge.to_h
    return 'not asked' if judge.empty?
    return "no verdict (#{judge['unusable']}#{": #{cell(judge['detail'], DETAIL_LIMIT)}" if judge['detail'].present?})" if judge['unusable']

    "#{judge['pass'] ? 'pass' : 'FAIL'}#{": #{cell(judge['reason'], DETAIL_LIMIT)}" if judge['reason'].present?}"
  end

  # The transfers and the council of the turn: who handed the conversation to whom, and how each part of a council ended.
  def coordination_lines(record)
    lines = []
    transfers = Array(record['transfers'])
    lines << "- Transfers: #{transfers.map { |item| "#{item['from']} -> #{item['to']}" }.join('; ')}" if transfers.any?
    council = record['council'].to_h
    if council.any?
      parts = Array(council['parts']).map { |part| "#{part['owner']}: #{part['state']}#{' (acted)' if part['acted']}" }.join('; ')
      lines << "- Council: #{[parts.presence, ("editor fallback #{council['editor_fallback']}" if council['editor_fallback'])].compact.join('; ').presence || 'no parts'}"
    end
    lines << "- Silent handoff: the conversation was handed to staff with no text for the patient" if record['silent_handoff']
    lines
  end

  def tool_calls_text(calls)
    return 'none' if calls.blank?

    calls.map do |call|
      text = "#{call['agent'] ? "#{call['agent']}: " : ''}#{call['tool']}#{call['success'] == false ? ' [failed]' : ''}"
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
