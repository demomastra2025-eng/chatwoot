# frozen_string_literal: true

# The release gate of a benchmark run. PASS needs all of
#   - every critical check passed (100%): one failure of gate items a-f blocks the release, in any run,
#   - an overall score of at least 95%: the share of scored turns on which no check failed (with repeated runs, see "Repeated runs"),
#   - every failed check triaged by a person (agent_bug, test_bug or judge_error),
#   - gate items a and f put to the test: the run holds appointment expectations that pin a start time, and a turn in which
#     the customer asks for a person (see `coverage`),
#   - a run that was not cut short (a run stopped by the budget or by an unexpected model scored only part of the fixtures),
#   - a handoff that is silent: the synthetic account's handoff notice is blank, so the text checks that are not put to a handoff
#     turn do not hide a sentence the patient would read (`silent_handoff: false` is a blocker). nil means "not checked" for a report
#     that has no handoff turn; when the runner could not read the notice (`silent_handoff_error`), or a turn is a silent handoff and
#     nothing proves the notice blank, the gate is blocked as well: the text of such a turn was not checked, and
#   - every required check evaluated (see "Not evaluated").
# A run that fails none of the hard rules but has failed checks nobody has triaged yet is PENDING_TRIAGE, which is not a
# pass. `critical passed/total` counts checks put to a turn (see Scorer::CHECKS and the `evaluated` list of a case);
# `overall passed/total` counts turns. Human triage labels are reported next to the raw verdict: `after_triage` drops the
# failures a person signed as test_bug or judge_error. It never replaces the raw verdict.
#
# Facts and hints. Only the checks of facts (the database, the operations ledger, the tool calls and results, the events, the schemas)
# fail a turn. The checks that read text (Scorer::HINT_CHECKS) give hints: they never fail a turn or the gate by themselves (owner
# decision 2A). The rubric judge decides by meaning with the hints in its evidence, and the report lists them for a person (Review).
# `hints` counts them per run, the critical ones apart.
#
# Not evaluated (owner decision 3A). The text of a reply is judged by the rubric judge. A turn whose required judge check got no verdict
# (`not_evaluated` on the case: the call failed three times, or the answer was no verdict) is neither passed nor failed. While any turn is
# left so, the verdict is INCOMPLETE_EVALUATION, never PASS; a failure still makes it FAIL. A run that played without the judge (`judge:
# false` in the report) leaves the text of every reply unjudged: it is INCOMPLETE_EVALUATION as well. A report that does not say (nil) is
# an older one and is read as before.
#
# Repeated runs. With RUNS=k a turn passes only when it passes in all k runs (pass^k), so a dialogue that fails once in three is not
# reliable: the overall score counts the turns of the dialogues, one each, and a turn that failed in any run is failed. The report gives
# the pass^k of the dialogues (`dialogues`), the score of each run (`runs`: the per-turn pass rate, the critical failures and the critical
# hints), and the number of turns not evaluated.
#
# A failure of the infrastructure under the agents (Scorer::INFRA_CHECKS: a technical handoff, a provider error, the fallback
# sentence) fails its turn like any other, and needs a triage; `infra` counts these turns apart so that they are not read as
# agent quality.
class Captain::Evals::RoutingBenchmark::Gate
  THRESHOLD = 95.0
  # Older reports carry no `evaluated` list; these checks existed then and ran on every turn (and still are checks of facts).
  LEGACY_CRITICAL_CHECKS = %w[duplicate_operation wrong_patient].freeze
  NOT_SILENT = 'the handoff notice of the synthetic account is not blank: a handoff is not silent, and its text is not checked'
  UNPROVEN_CAUSE = 'the report has silent handoff turns and no proof that the notice is blank'
  INCOMPLETE = 'INCOMPLETE_EVALUATION'

  class << self
    # cases: the report's cases (string or symbol keys)
    # judge: whether the run asked the rubric judge (true / false), nil for a report that does not say
    def call(cases, aborted: false, abort_reason: nil, labels: {}, silent_handoff: nil, silent_handoff_error: nil, judge: nil)
      cases = cases.map { |item| item.to_h.deep_stringify_keys }
      triage = triage_summary(cases, labels)
      proof = { silent_handoff: silent_handoff, silent_handoff_error: silent_handoff_error, judge: judge }
      raw = evaluate(cases, aborted, abort_reason, triage[:untriaged], **proof)
      raw[:triage] = triage
      raw[:after_triage] = evaluate(cases, aborted, abort_reason, triage[:untriaged], labels: labels, **proof) if labels.any?
      raw
    end

    # The gate of a stored report (string or symbol keys): the cases and what the run says about itself.
    def for_report(report, labels: {})
      report = report.to_h.deep_stringify_keys
      call(report.fetch('cases'), aborted: report['aborted'], abort_reason: report['abort_reason'], labels: labels,
                                  silent_handoff: report['silent_handoff'], silent_handoff_error: report['silent_handoff_error'], judge: report['judge'])
    end

    # Severity of a failure: the one stored at scoring time, else the one the table gives for the reason.
    def severity_of(failure) = failure['severity'] || Captain::Evals::RoutingBenchmark::Scorer.severity_for(failure['id'])

    # The checks a case was put through: the stored list, else the checks an older report ran on every turn plus its failures. A check
    # that reads text is no check of the gate (older reports list them as evaluated).
    def evaluated_ids(item)
      ids = item['evaluated'].is_a?(Array) ? item['evaluated'] : LEGACY_CRITICAL_CHECKS + Array(item['reasons'])
      ids.reject { |id| Captain::Evals::RoutingBenchmark::Scorer.hint?(id) }
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

    # A turn left without the verdict of a required check (the judge): neither passed nor failed.
    def not_evaluated?(item) = Captain::Evals::RoutingBenchmark::Scorer.not_evaluated?(item)

    private

    def evaluate(cases, aborted, abort_reason, untriaged, labels: {}, silent_handoff: nil, silent_handoff_error: nil, judge: nil)
      scored = cases.map { |item| score(item, labels) }
      critical = critical_section(scored)
      overall = overall_section(scored)
      unblocked = overall_counts(scored.reject { |entry| blocked?(entry) })
      coverage, uncovered = coverage_section(scored)
      incomplete = incomplete_reasons(scored, judge)
      blockers = []
      blockers << "#{critical[:failed]} critical failure(s)" if critical[:failed].positive?
      blockers << overall_blocker(overall, unblocked) if overall[:pct] < THRESHOLD && (overall[:total].positive? || incomplete.empty?)
      blockers << "the run was cut short (#{abort_reason || 'aborted'})" if aborted
      blockers << 'no turn was scored' if scored.empty?
      blockers.concat(silent_handoff_blockers(cases, silent_handoff, silent_handoff_error))
      blockers.concat(uncovered)
      pending = untriaged.positive? ? ["#{untriaged} failed check(s) not triaged by a person"] : []
      verdict = verdict_of(blockers, incomplete, pending)
      { verdict: verdict, blockers: blockers + incomplete + pending, critical: critical, overall: overall, overall_unblocked: unblocked,
        runs: runs_section(scored), dialogues: dialogues_section(scored), not_evaluated: not_evaluated_section(scored), hints: hints_section(scored),
        coverage: coverage, by_severity: by_severity(scored), checks: checks(scored), infra: infra_section(scored), judge: judge,
        silent_handoff: silent_handoff, silent_handoff_error: silent_handoff_error.presence }.compact
    end

    def verdict_of(blockers, incomplete, pending)
      return 'FAIL' if blockers.any?
      return INCOMPLETE if incomplete.any?

      pending.any? ? 'PENDING_TRIAGE' : 'PASS'
    end

    # Why the evaluation is not complete: turns that wait for a verdict, a run that played without the judge.
    def incomplete_reasons(scored, judge)
      reasons = []
      left = scored.count { |entry| left_unevaluated?(entry) }
      reasons << "#{left} turn(s) not evaluated: a required check has no verdict (the rubric judge gave none)" if left.positive?
      reasons << 'the rubric judge was off: the text of the replies was not evaluated' if judge == false
      reasons
    end

    # The 95% bar is held to every turn (the verdict). When turns were played on a conversation that staff owned, the message says what
    # the score is without them: those turns are an artifact of the run (see Runner), and a reader must see both numbers.
    def overall_blocker(overall, unblocked)
      text = "overall #{overall[:pct]}% is below #{THRESHOLD}%"
      text += " (pass^#{overall[:runs]}: a turn passes only when it passes in every run)" if overall[:runs].to_i > 1
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

    # The score over the turns of the dialogues. A turn is one position (fixture, dialogue, turn number) whatever the number of runs; with
    # several runs it passes only when it passed in all of them (pass^k), is failed when it failed in any, and is not evaluated when it
    # failed in none and one run left it without a verdict. Turns not evaluated are out of the percentage, and the verdict says so.
    def overall_counts(scored)
      positions = scored.group_by { |entry| position_key(entry[:item]) }.values
      states = positions.map { |entries| position_state(entries) }
      passed = states.count(:pass)
      failed = states.count(:fail)
      total = passed + failed
      only_minor = positions.count do |entries|
        failures = entries.flat_map { |entry| entry[:failures] }
        failures.any? && failures.all? { |failure| severity_of(failure) == 'minor' }
      end
      { passed: passed, total: total, pct: percentage(passed, total), threshold: THRESHOLD, failed_turns: failed, not_evaluated: states.count(:not_evaluated),
        runs: run_numbers(scored).size, failed_only_on_minor_checks: only_minor,
        turns_with_critical_failure: positions.count { |entries| entries.any? { |entry| critical_failure?(entry) } } }
    end

    def position_key(item) = [File.basename(item['fixture'].to_s), item['dialogue'], item['turn']]

    def position_state(entries)
      return :fail if entries.any? { |entry| entry[:failures].any? }
      return :not_evaluated if entries.any? { |entry| not_evaluated?(entry[:item]) }

      :pass
    end

    def critical_failure?(entry) = entry[:failures].any? { |failure| severity_of(failure) == 'critical' }

    # A turn that waits for a verdict and failed no fact check. A turn that failed one is failed, whatever the judge said.
    def left_unevaluated?(entry) = entry[:failures].empty? && not_evaluated?(entry[:item])

    def run_numbers(scored) = scored.map { |entry| entry[:item]['run'] || 1 }.uniq.sort

    # The score of each run on its own: the per-turn pass rate (turns not evaluated are out of it), the critical failures, and the hints
    # (the critical ones apart).
    def runs_section(scored)
      scored.group_by { |entry| entry[:item]['run'] || 1 }.sort.to_h do |run, entries|
        failed = entries.count { |entry| entry[:failures].any? }
        left = entries.count { |entry| left_unevaluated?(entry) }
        passed = entries.size - failed - left
        hints = entries.flat_map { |entry| hints_of(entry) }
        [run, { turns: entries.size, passed: passed, failed: failed, not_evaluated: left, pct: percentage(passed, passed + failed),
                critical_failures: entries.sum { |entry| entry[:failures].count { |failure| severity_of(failure) == 'critical' } },
                hints: hints.size, critical_hints: hints.count { |hint| hint_severity(hint) == 'critical' } }]
      end
    end

    # The pass^k of the dialogues: the dialogues that passed on every turn in EVERY run. A dialogue that failed a turn in some run failed; one
    # that failed none but has a turn not evaluated is incomplete.
    def dialogues_section(scored)
      runs = run_numbers(scored)
      groups = scored.group_by { |entry| [File.basename(entry[:item]['fixture'].to_s), entry[:item]['dialogue']] }.values
      states = groups.map { |entries| dialogue_state(entries, runs.size) }
      { runs: runs.size, total: groups.size, passed_every_run: states.count(:pass), failed: states.count(:fail), not_evaluated: states.count(:not_evaluated),
        pass_k_pct: percentage(states.count(:pass), groups.size) }
    end

    def dialogue_state(entries, runs)
      return :fail if entries.any? { |entry| entry[:failures].any? }
      return :not_evaluated if entries.any? { |entry| not_evaluated?(entry[:item]) }

      entries.map { |entry| entry[:item]['run'] || 1 }.uniq.size == runs ? :pass : :not_evaluated
    end

    # The turns left without the verdict of a required check, by check.
    def not_evaluated_section(scored)
      left = scored.select { |entry| left_unevaluated?(entry) }
      by_check = left.flat_map { |entry| Array(entry[:item]['not_evaluated']).presence || ['judge'] }.tally.sort.to_h
      { turns: left.size, by_check: by_check }
    end

    # The hits of the checks that read text: never failures. Per check: on how many turns, and the most severe.
    def hints_section(scored)
      hints = scored.flat_map { |entry| hints_of(entry) }
      by_check = hints.group_by { |hint| base(hint['id']) }.transform_values do |list|
        { turns: list.size, severity: list.map { |hint| hint_severity(hint) }.min_by { |severity| Captain::Evals::RoutingBenchmark::Triage.severity_rank(severity) } }
      end
      { total: hints.size, critical: hints.count { |hint| hint_severity(hint) == 'critical' },
        by_check: by_check.sort_by { |name, row| [Captain::Evals::RoutingBenchmark::Triage.severity_rank(row[:severity]), name] }.to_h }
    end

    def hints_of(entry) = Captain::Evals::RoutingBenchmark::Review.hints_of(entry[:item])

    def hint_severity(hint) = hint['severity'] || severity_for(hint['id'])

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
      asked = turns.count { |item| asked_for_person?(item) }
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

    # The fixture says the customer asks for a person (`human_request: true`): a missing handoff is then a fact. A turn that only the wording
    # detector reads as a request gives a hint at most, so it puts nothing of item f to the test.
    def asked_for_person?(item) = item.dig('human_request', 'value') == true && item.dig('human_request', 'source') == 'fixture'

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
