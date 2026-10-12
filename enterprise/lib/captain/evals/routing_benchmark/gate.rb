# frozen_string_literal: true

# The release gate of a benchmark run. PASS needs both
#   - every critical check passed (100%): one failure of gate items a-f blocks the release, and
#   - an overall score of at least 95%: the share of scored turns on which no check failed.
# and a run that was not cut short (a run stopped by the budget or by an unexpected model scored only part of the
# fixtures). `critical passed/total` counts checks put to a turn (see Scorer::CHECKS and the `evaluated` list of a case);
# `overall passed/total` counts turns. Human triage labels (agent_bug, test_bug, judge_error) are reported next to the
# raw verdict: `after_triage` drops the failures a person signed as test_bug or judge_error. It never replaces the raw verdict.
class Captain::Evals::RoutingBenchmark::Gate
  THRESHOLD = 95.0
  # Older reports carry no `evaluated` list; these checks existed then and ran on every turn.
  LEGACY_CRITICAL_CHECKS = %w[false_success_claim duplicate_operation wrong_patient internal_text_leak].freeze

  class << self
    # cases: the report's cases (string or symbol keys)
    def call(cases, aborted: false, abort_reason: nil, labels: {})
      cases = cases.map { |item| item.to_h.deep_stringify_keys }
      raw = evaluate(cases, aborted, abort_reason)
      raw[:triage] = triage_summary(cases, labels)
      raw[:after_triage] = evaluate(cases, aborted, abort_reason, labels: labels) if labels.any?
      raw
    end

    # Severity of a failure: the one stored at scoring time, else the one the table gives for the reason.
    def severity_of(failure) = failure['severity'] || Captain::Evals::RoutingBenchmark::Scorer.severity_for(failure['id'])

    private

    def evaluate(cases, aborted, abort_reason, labels: {})
      scored = cases.map { |item| score(item, labels) }
      critical = critical_section(scored)
      overall = overall_section(scored)
      blockers = []
      blockers << "#{critical[:failed]} critical failure(s)" if critical[:failed].positive?
      blockers << "overall #{overall[:pct]}% is below #{THRESHOLD}%" if overall[:pct] < THRESHOLD
      blockers << "the run was cut short (#{abort_reason || 'aborted'})" if aborted
      blockers << 'no turn was scored' if scored.empty?
      { verdict: blockers.empty? ? 'PASS' : 'FAIL', blockers: blockers, critical: critical, overall: overall,
        by_severity: by_severity(scored), checks: checks(scored) }
    end

    # A case reduced to what the gate counts: its failures (minus the ones a person signed off) and its evaluated checks.
    def score(item, labels)
      failures = Captain::Evals::RoutingBenchmark::Triage.failures_of(item)
      failures = failures.reject do |failure|
        label = labels[Captain::Evals::RoutingBenchmark::Triage.key(item['fixture'], item['dialogue'], item['turn'], failure['id'])]
        Captain::Evals::RoutingBenchmark::Triage::NOT_AGENT.include?(label)
      end
      { item: item, failures: failures, evaluated: evaluated_ids(item) }
    end

    def evaluated_ids(item)
      return item['evaluated'] if item['evaluated'].is_a?(Array)

      LEGACY_CRITICAL_CHECKS + Array(item['reasons'])
    end

    def critical_section(scored)
      total = 0
      failures = []
      scored.each do |entry|
        critical_ids = (entry[:evaluated] | entry[:failures].pluck('id')).select { |id| severity_for(id) == 'critical' }
        total += critical_ids.size
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

    def by_severity(scored)
      Captain::Evals::RoutingBenchmark::Scorer::SEVERITIES.index_with do |severity|
        evaluated = scored.sum { |entry| (entry[:evaluated] | entry[:failures].pluck('id')).count { |id| severity_for(id) == severity } }
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
