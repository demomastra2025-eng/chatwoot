# frozen_string_literal: true

# The release gate of a benchmark run. PASS needs all of
#   - every critical check passed (100%): one failure of gate items a-f blocks the release,
#   - an overall score of at least 95%: the share of scored turns on which no check failed,
#   - every failed check triaged by a person (agent_bug, test_bug or judge_error),
#   - gate items a and f put to the test: the run holds appointment expectations that pin a start time, and a turn in which
#     the customer asks for a person (see `coverage`),
#   - a run that was not cut short (a run stopped by the budget or by an unexpected model scored only part of the fixtures), and
#   - a handoff that is silent: the synthetic account's handoff notice is blank, so the text checks that are not put to a handoff
#     turn do not hide a sentence the patient would read (`silent_handoff: false` is a blocker). nil means "not checked" for a report
#     that has no handoff turn; when the runner could not read the notice (`silent_handoff_error`), or a turn is a silent handoff and
#     nothing proves the notice blank, the gate is blocked as well: the text of such a turn was not checked.
# A run that fails none of the hard rules but has failed checks nobody has triaged yet is PENDING_TRIAGE, which is not a
# pass. `critical passed/total` counts checks put to a turn (see Scorer::CHECKS and the `evaluated` list of a case);
# `overall passed/total` counts turns. Human triage labels are reported next to the raw verdict: `after_triage` drops the
# failures a person signed as test_bug or judge_error. It never replaces the raw verdict.
#
# A failure of the infrastructure under the agents (Scorer::INFRA_CHECKS: a technical handoff, a provider error, the fallback
# sentence) fails its turn like any other, and needs a triage; `infra` counts these turns apart so that they are not read as
# agent quality.
class Captain::Evals::RoutingBenchmark::Gate
  THRESHOLD = 95.0
  # Older reports carry no `evaluated` list; these checks existed then and ran on every turn.
  LEGACY_CRITICAL_CHECKS = %w[false_success_claim duplicate_operation wrong_patient internal_text_leak].freeze
  NOT_SILENT = 'the handoff notice of the synthetic account is not blank: a handoff is not silent, and its text is not checked'
  UNPROVEN_CAUSE = 'the report has silent handoff turns and no proof that the notice is blank'

  class << self
    # cases: the report's cases (string or symbol keys)
    def call(cases, aborted: false, abort_reason: nil, labels: {}, silent_handoff: nil, silent_handoff_error: nil)
      cases = cases.map { |item| item.to_h.deep_stringify_keys }
      triage = triage_summary(cases, labels)
      proof = { silent_handoff: silent_handoff, silent_handoff_error: silent_handoff_error }
      raw = evaluate(cases, aborted, abort_reason, triage[:untriaged], **proof)
      raw[:triage] = triage
      raw[:after_triage] = evaluate(cases, aborted, abort_reason, triage[:untriaged], labels: labels, **proof) if labels.any?
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

    # An expectation that can tell a wrong booking from a right one: it pins the start time (`params.starts_at` of the v2 schema, or
    # the symbolic `starts_at`), and a move also pins the appointment it starts from (`previous_starts_at`). Without the old start, a
    # move of the wrong appointment to the requested time passes. A wrong time is an operation_mismatch; the doctor, the service and
    # the patient are checked only where the fixture pins them, and the reply is read against the booked row (reply_record_mismatch).
    def specific?(operation)
      check = Captain::Evals::RoutingBenchmark::OperationCheck
      check.expected_start(operation).present? && (check.kind_of(operation) != 'update' || operation['previous_starts_at'].present?)
    end

    private

    def evaluate(cases, aborted, abort_reason, untriaged, labels: {}, silent_handoff: nil, silent_handoff_error: nil)
      scored = cases.map { |item| score(item, labels) }
      critical = critical_section(scored)
      overall = overall_section(scored)
      unblocked = overall_counts(scored.reject { |entry| blocked?(entry) })
      coverage, uncovered = coverage_section(scored)
      blockers = []
      blockers << "#{critical[:failed]} critical failure(s)" if critical[:failed].positive?
      blockers << overall_blocker(overall, unblocked) if overall[:pct] < THRESHOLD
      blockers << "the run was cut short (#{abort_reason || 'aborted'})" if aborted
      blockers << 'no turn was scored' if scored.empty?
      blockers.concat(silent_handoff_blockers(cases, silent_handoff, silent_handoff_error))
      blockers.concat(uncovered)
      pending = untriaged.positive? ? ["#{untriaged} failed check(s) not triaged by a person"] : []
      verdict = blockers.any? ? 'FAIL' : (pending.any? ? 'PENDING_TRIAGE' : 'PASS')
      { verdict: verdict, blockers: blockers + pending, critical: critical, overall: overall, overall_unblocked: unblocked, coverage: coverage,
        by_severity: by_severity(scored), checks: checks(scored), infra: infra_section(scored), silent_handoff: silent_handoff,
        silent_handoff_error: silent_handoff_error.presence }.compact
    end

    # The 95% bar is held to every turn (the verdict). When turns were played on a conversation that staff owned, the message says what
    # the score is without them: those turns are an artifact of the run (see Runner), and a reader must see both numbers.
    def overall_blocker(overall, unblocked)
      text = "overall #{overall[:pct]}% is below #{THRESHOLD}%"
      return text unless overall[:blocked_turns].to_i.positive?

      "#{text} (#{unblocked[:pct]}% without the #{overall[:blocked_turns]} blocked turn(s))"
    end

    # A turn the runner played on a conversation that staff owned and nobody had given back (`blocked: true` on the case).
    def blocked?(entry) = entry[:item]['blocked'] == true

    # A notice that is not blank (a handoff is not silent), or one that is not proven blank: the runner could not read it (it rescued an
    # error), or silent handoff turns are in the report and nothing says the notice is blank. The text of those turns was skipped on trust.
    def silent_handoff_blockers(cases, silent_handoff, error)
      return [NOT_SILENT] if silent_handoff == false
      return [] unless silent_handoff.nil? && (error.present? || cases.any? { |item| item['silent_handoff'] == true })

      cause = error.present? ? "the notice could not be read (#{error})" : UNPROVEN_CAUSE
      ["silent handoff not proven: #{cause}; the text of a handoff turn is not checked"]
    end

    # The turns that ended in a failure of the infrastructure under the agents, by check.
    def infra_section(scored)
      by_check = Hash.new(0)
      turns = scored.count do |entry|
        found = entry[:failures].filter_map { |failure| base(failure['id']) }.select { |check| Captain::Evals::RoutingBenchmark::Scorer::INFRA_CHECKS.include?(check) }
        found.each { |check| by_check[check] += 1 }
        found.any?
      end
      { turns: turns, by_check: by_check.sort.to_h }
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

    # The score over all turns, with how many of them are blocked.
    def overall_section(scored)
      overall_counts(scored).merge(blocked_turns: scored.count { |entry| blocked?(entry) })
    end

    def overall_counts(scored)
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
    #   a  appointment expectations that pin the start time: without them a booking at the wrong time is not noticed
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
        blockers << "item a not covered: #{expected - specific} of #{expected} expected operations pin no start time (params.starts_at), " \
                    'or pin no previous_starts_at for a move'
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
