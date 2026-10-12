# frozen_string_literal: true

# The release gate of a benchmark run. PASS needs all of
#   - every critical check passed (100%): one failure of gate items a-f blocks the release,
#   - an overall score of at least 95%: the share of scored turns on which no check failed,
#   - every failed check triaged by a person (agent_bug, test_bug or judge_error),
#   - gate items a and f put to the test: the run holds appointment expectations that name the doctor and the time, and a
#     turn in which the customer asks for a person (see `coverage`), and
#   - a run that was not cut short (a run stopped by the budget or by an unexpected model scored only part of the fixtures).
# A run that fails none of the hard rules but has failed checks nobody has triaged yet is PENDING_TRIAGE, which is not a
# pass. `critical passed/total` counts checks put to a turn (see Scorer::CHECKS and the `evaluated` list of a case);
# `overall passed/total` counts turns. Human triage labels are reported next to the raw verdict: `after_triage` drops the
# failures a person signed as test_bug or judge_error. It never replaces the raw verdict.
class Captain::Evals::RoutingBenchmark::Gate
  THRESHOLD = 95.0
  # Older reports carry no `evaluated` list; these checks existed then and ran on every turn.
  LEGACY_CRITICAL_CHECKS = %w[false_success_claim duplicate_operation wrong_patient internal_text_leak].freeze

  class << self
    # cases: the report's cases (string or symbol keys)
    def call(cases, aborted: false, abort_reason: nil, labels: {})
      cases = cases.map { |item| item.to_h.deep_stringify_keys }
      triage = triage_summary(cases, labels)
      raw = evaluate(cases, aborted, abort_reason, triage[:untriaged])
      raw[:triage] = triage
      raw[:after_triage] = evaluate(cases, aborted, abort_reason, triage[:untriaged], labels: labels) if labels.any?
      raw
    end

    # Severity of a failure: the one stored at scoring time, else the one the table gives for the reason.
    def severity_of(failure) = failure['severity'] || Captain::Evals::RoutingBenchmark::Scorer.severity_for(failure['id'])

    # The checks a case was put through: the stored list, else the checks an older report ran on every turn plus its failures.
    def evaluated_ids(item)
      return item['evaluated'] if item['evaluated'].is_a?(Array)

      LEGACY_CRITICAL_CHECKS + Array(item['reasons'])
    end

    # The appointment expectations of a turn (a hash with an `expectation`) that mean a change ("count: 0" says "no such
    # row", which tests nothing).
    def expected_operations(item)
      Array(item.dig('expectation', 'operations')).select do |operation|
        operation['model'] == 'appointment' && !(operation.key?('count') && operation['count'].to_i.zero?)
      end
    end

    # An expectation that can tell a wrong booking from a right one: it names the doctor and the time, and for a booking or
    # a move also the service or the patient.
    def specific?(operation)
      return false unless operation['resource'].present? && operation['starts_at'].present?

      Captain::Evals::RoutingBenchmark::OperationCheck.kind_of(operation) == 'cancel' ||
        %w[service patient patient_name].any? { |key| operation[key].present? }
    end

    private

    def evaluate(cases, aborted, abort_reason, untriaged, labels: {})
      scored = cases.map { |item| score(item, labels) }
      critical = critical_section(scored)
      overall = overall_section(scored)
      coverage, uncovered = coverage_section(scored)
      blockers = []
      blockers << "#{critical[:failed]} critical failure(s)" if critical[:failed].positive?
      blockers << "overall #{overall[:pct]}% is below #{THRESHOLD}%" if overall[:pct] < THRESHOLD
      blockers << "the run was cut short (#{abort_reason || 'aborted'})" if aborted
      blockers << 'no turn was scored' if scored.empty?
      blockers.concat(uncovered)
      pending = untriaged.positive? ? ["#{untriaged} failed check(s) not triaged by a person"] : []
      verdict = blockers.any? ? 'FAIL' : (pending.any? ? 'PENDING_TRIAGE' : 'PASS')
      { verdict: verdict, blockers: blockers + pending, critical: critical, overall: overall, coverage: coverage,
        by_severity: by_severity(scored), checks: checks(scored) }
    end

    # A case reduced to what the gate counts: its failures (minus the ones a person signed off) and its evaluated checks.
    def score(item, labels)
      failures = Captain::Evals::RoutingBenchmark::Triage.failures_of(item)
      failures = failures.reject do |failure|
        Captain::Evals::RoutingBenchmark::Triage::NOT_AGENT.include?(Captain::Evals::RoutingBenchmark::Triage.label_for(labels, item, failure))
      end
      { item: item, failures: failures, evaluated: evaluated_ids(item) }
    end

    # The checks put to a turn, one unit each. A failure "reply_leak:latin" is the failed form of the evaluated check
    # "reply_leak": the plain id is dropped, so one check is not counted once as passed and once as failed.
    def units(entry)
      failed = entry[:failures].pluck('id')
      failed_bases = failed.filter_map { |id| base(id) if id.include?(':') }
      (entry[:evaluated] | failed).reject { |id| id.exclude?(':') && failed_bases.include?(id) }
    end

    def critical_section(scored)
      total = 0
      failures = []
      scored.each do |entry|
        total += units(entry).count { |id| severity_for(id) == 'critical' }
        entry[:failures].select { |failure| severity_of(failure) == 'critical' }.each { |failure| failures << failure_row(entry[:item], failure) }
      end
      failed = failures.size
      { passed: total - failed, total: total, failed: failed, pct: percentage(total - failed, total), failures: failures }
    end

    def overall_section(scored)
      total = scored.size
      passed = scored.count { |entry| entry[:failures].empty? }
      only_minor = scored.count do |entry|
        entry[:failures].any? && entry[:failures].all? { |failure| severity_of(failure) == 'minor' }
      end
      { passed: passed, total: total, pct: percentage(passed, total), threshold: THRESHOLD, failed_turns: total - passed,
        failed_only_on_minor_checks: only_minor,
        turns_with_critical_failure: scored.count { |entry| entry[:failures].any? { |failure| severity_of(failure) == 'critical' } } }
    end

    # What the run put to the test, per gate item. A critical check that is "evaluated" on every turn proves nothing on a
    # turn that never gives it a chance to fail. Items a and f depend on the fixtures, so they block the gate:
    #   a  appointment expectations that name the doctor and the time (and the service or the patient for a booking or a
    #      move): without them a booking with the wrong doctor or time is not noticed
    #   f  turns in which the customer asks for a person: without them a missing handoff is not noticed
    # The other items are counted for the report only (b: replies that claim something; c: turns that changed an
    # appointment; d, e: patient replies that were scanned). Returns the table and the blockers.
    def coverage_section(scored)
      turns = scored.pluck(:item)
      operations = turns.flat_map { |item| expected_operations(item) }
      specific = operations.count { |operation| specific?(operation) }
      asked = turns.count { |item| item.dig('human_request', 'value') == true }
      replies = turns.count { |item| item['patient_text'].present? }
      table = {
        'a' => { covered: specific, expected: operations.size },
        'b' => { covered: turns.count { |item| claim_turn?(item) } },
        'c' => { covered: turns.count { |item| item['db_delta'].present? } },
        'd' => { covered: replies },
        'e' => { covered: replies },
        'f' => { covered: asked }
      }
      [table, scored.empty? ? [] : coverage_blockers(operations.size, specific, asked)]
    end

    def coverage_blockers(expected, specific, asked)
      blockers = []
      if expected.zero?
        blockers << 'item a not covered: no appointment operation is expected anywhere in this run'
      elsif specific < expected
        blockers << "item a not covered: #{expected - specific} of #{expected} expected operations have no doctor/time (or service/patient)"
      end
      blockers << 'item f not covered: no turn asks for a person' if asked.zero?
      blockers
    end

    def claim_turn?(item)
      Array(item.dig('evidence', 'claimed_operations')).any? || Array(item.dig('evidence', 'handoff_claims')).any?
    end

    def by_severity(scored)
      Captain::Evals::RoutingBenchmark::Scorer::SEVERITIES.index_with do |severity|
        evaluated = scored.sum { |entry| units(entry).count { |id| severity_for(id) == severity } }
        failed = scored.sum { |entry| entry[:failures].count { |failure| severity_of(failure) == severity } }
        { evaluated: evaluated, failed: failed }
      end
    end

    # Per check (the reason without its argument): severity, gate item, on how many turns it was put and on how many it failed.
    # A check whose severity depends on its argument (forbidden_tool) shows the most severe one it met in this run.
    def checks(scored)
      table = Hash.new { |hash, base| hash[base] = { evaluated: 0, failed: 0, severities: [] } }
      scored.each do |entry|
        entry[:evaluated].map { |id| base(id) }.uniq.each { |base| table[base][:evaluated] += 1 }
        entry[:failures].map { |failure| base(failure['id']) }.uniq.each { |base| table[base][:failed] += 1 }
        (entry[:evaluated] | entry[:failures].pluck('id')).each { |id| table[base(id)][:severities] << severity_for(id) }
      end
      rows = table.map { |base, stats| [base, check_row(base, stats)] }
      rows.sort_by { |base, row| [Captain::Evals::RoutingBenchmark::Triage.severity_rank(row[:severity]), base] }.to_h
    end

    def check_row(base, stats)
      worst = stats[:severities].min_by { |severity| Captain::Evals::RoutingBenchmark::Triage.severity_rank(severity) } || severity_for(base)
      { evaluated: stats[:evaluated], failed: stats[:failed], severity: worst, gate: Captain::Evals::RoutingBenchmark::Scorer.gate_item_for(base) }
    end

    def triage_summary(cases, labels)
      records = Captain::Evals::RoutingBenchmark::Triage.records(cases, labels: labels)
      counts = Captain::Evals::RoutingBenchmark::Triage::LABELS.index_with { |label| records.count { |record| record['triage'] == label } }
      triaged = counts.values.sum
      { failed_checks: records.size, triaged: triaged, untriaged: records.size - triaged }.merge(counts.symbolize_keys)
    end

    def failure_row(item, failure)
      { fixture: File.basename(item['fixture'].to_s), dialogue: item['dialogue'], run: item['run'], turn: item['turn'],
        check: failure['id'], gate: failure['gate'], detail: failure['detail'] }.compact
    end

    def severity_for(id) = Captain::Evals::RoutingBenchmark::Scorer.severity_for(id)

    def base(id) = Captain::Evals::RoutingBenchmark::Scorer.base_check(id)

    def percentage(count, total) = total.zero? ? 0.0 : (count * 100.0 / total).round(2)
  end
end
