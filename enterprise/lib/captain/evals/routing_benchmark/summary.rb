# frozen_string_literal: true

# The numbers a run reports besides the release gate, computed from its cases (string or symbol keys, so an older output can be
# summarised too):
#   - dialogues: how many dialogues passed (every turn passed), per-run pass rates, pass^k (the dialogues that passed in EVERY run of
#     k repeats: a dialogue that fails once in three runs is not reliable), and the turns that are `blocked`
#   - by_category and by_reason: turns and dialogues per category (the dialogue id without its number), failed turns per check
#   - infra: the turns that ended in a failure of the infrastructure under the agents (Scorer::INFRA_CHECKS). They are left out of
#     every accuracy below, so a provider outage does not read as a routing bug; the gate still counts them as failed turns
#   - routing_accuracy (the agent holding the conversation), transfer_accuracy (expect.transfers), staff_handoff_accuracy (true or
#     false), acts_accuracy (the owner made the call): the share of the turns that state the expectation and ran to their end
#
# A turn is `blocked` when an earlier turn of the same dialogue failed on something the later turns build on (a booking that was
# not made, a wrong holder of the conversation, an aborted run), and the turn itself failed: its failure is probably the cascade of
# the first one, so the dialogue summary shows it as blocked and not as a new finding. A turn the runner played on a conversation that
# staff owned (`blocked: true` on the case: no `staff:` step gave it back to the AI, which cannot happen live) is blocked as well when it
# fails. The turns stay failed turns for the gate; the gate also reports the score without the turns the runner marked (`overall_unblocked`).
#
# A judge that gave no verdict (`judge_unusable`) is no failure of the turn: the turns that carry it are counted apart.
class Captain::Evals::RoutingBenchmark::Summary
  # What the later turns of a dialogue depend on.
  STATE_CHECKS = %w[missing_operation operation_mismatch unexpected_mutation forbidden_tool succeeded_forbidden missing_act missing_tool
                    wrong_agent wrong_transfers council_changed_hands staff_handoff_missing staff_handoff_unexpected duplicate_operation
                    wrong_patient double_booking technical_handoff provider_error runtime_error].freeze
  # The checks that decide each accuracy.
  ACCURACY_CHECKS = {
    routing: %w[wrong_agent], transfer: %w[wrong_transfers], staff_handoff: %w[staff_handoff_missing staff_handoff_unexpected],
    acts: %w[missing_act]
  }.freeze

  class << self
    def call(cases)
      new(cases).result
    end
  end

  def initialize(cases)
    @cases = cases.map { |item| item.to_h.deep_stringify_keys }
  end

  def result
    {
      infra: infra, judge_unusable: judge_unusable, routing_accuracy: accuracy(:routing), transfer_accuracy: accuracy(:transfer),
      staff_handoff_accuracy: accuracy(:staff_handoff), acts_accuracy: accuracy(:acts),
      dialogues: dialogue_totals, by_category: by_category, by_reason: by_reason, dialogue_summaries: summaries
    }
  end

  # { fixture, dialogue, run, category, turns, passed, failed, blocked, pass, statuses: ['pass', 'fail', 'blocked'], first_failure }
  def summaries
    @summaries ||= @cases.group_by { |item| [item['fixture'], item['dialogue'], item['run'] || 1] }.map do |(fixture, dialogue, run), turns|
      dialogue_summary(File.basename(fixture.to_s), dialogue, run, turns.sort_by { |item| item['turn'].to_i })
    end
  end

  private

  def dialogue_summary(fixture, dialogue, run, turns)
    statuses = turn_statuses(turns)
    first = turns.zip(statuses).find { |_item, status| status == 'fail' }
    {
      fixture: fixture, dialogue: dialogue, run: run, category: category_of(dialogue), turns: turns.size,
      passed: statuses.count('pass'), failed: statuses.count('fail'), blocked: statuses.count('blocked'),
      pass: statuses.all?('pass'), statuses: statuses, turn_numbers: turns.map { |item| item['turn'] },
      first_failure: first && { turn: first[0]['turn'], checks: failed_checks(first[0]) }
    }.compact
  end

  def turn_statuses(turns)
    blocked = false
    turns.map do |item|
      failed = failed_checks(item)
      status = turn_status(failed, blocked || item['blocked'] == true)
      blocked ||= (failed & STATE_CHECKS).any?
      status
    end
  end

  def turn_status(failed, blocked)
    return 'pass' if failed.empty?

    blocked ? 'blocked' : 'fail'
  end

  # The checks a turn failed. A judge without a verdict is no failure (older reports hold it as one).
  def failed_checks(item)
    scorer = Captain::Evals::RoutingBenchmark::Scorer
    Array(item['reasons']).reject { |reason| scorer.judge_unusable?(reason) }.map { |reason| scorer.base_check(reason) }.uniq
  end

  def category_of(dialogue) = dialogue.to_s.sub(/_\d+\z/, '')

  def infra_item?(item) = (failed_checks(item) & Captain::Evals::RoutingBenchmark::Scorer::INFRA_CHECKS).any?

  def infra
    items = @cases.select { |item| infra_item?(item) }
    by_check = items.flat_map { |item| failed_checks(item) & Captain::Evals::RoutingBenchmark::Scorer::INFRA_CHECKS }.tally.sort.to_h
    { turns: items.size, by_check: by_check }
  end

  # The turns whose rubric judge gave no verdict (the call failed, or the answer was no verdict), by cause: a warning of the turn in a run
  # of today, a failure in the report of an older run.
  def judge_unusable
    scorer = Captain::Evals::RoutingBenchmark::Scorer
    causes = @cases.map do |item|
      (Array(item['warnings']) + Array(item['reasons'])).map { |entry| scorer.base_check(entry) }.select { |check| scorer.judge_unusable?(check) }.uniq
    end
    { turns: causes.count(&:any?), by_check: causes.flatten.tally.sort.to_h }
  end

  # The share of the turns in scope with none of the failures of the given checks. Turns that ended in an infrastructure failure are
  # out of scope.
  def accuracy(kind)
    scope = @cases.reject { |item| infra_item?(item) }.select { |item| in_scope?(kind, item) }
    return if scope.empty?

    checks = ACCURACY_CHECKS.fetch(kind)
    (scope.count { |item| (failed_checks(item) & checks).empty? }.to_f / scope.size).round(4)
  end

  def in_scope?(kind, item)
    expect = item['expectation'].to_h
    case kind
    when :routing then expect.key?('agent') || expect.key?('agents') || item['expectation'].nil?
    when :transfer then expect.key?('transfers')
    when :staff_handoff then [true, false].include?(expect['staff_handoff'])
    when :acts then Array(expect['acts']).any?
    end
  end

  def dialogue_totals
    runs = summaries.pluck(:run).uniq.sort
    every_run = summaries.group_by { |item| [item[:fixture], item[:dialogue]] }
    stable = every_run.count { |_key, list| list.size == runs.size && list.all? { |item| item[:pass] } }
    {
      total: summaries.size, passed: summaries.count { |item| item[:pass] }, failed: summaries.count { |item| !item[:pass] },
      blocked_turns: summaries.sum { |item| item[:blocked] },
      per_run: runs.to_h { |run| [run, run_rate(summaries.select { |item| item[:run] == run })] },
      pass_k: { k: runs.size, dialogues: every_run.size, passed_every_run: stable, rate: every_run.empty? ? nil : (stable.to_f / every_run.size).round(4) }
    }
  end

  def run_rate(list) = { dialogues: list.size, passed: list.count { |item| item[:pass] } }

  def by_category
    summaries.group_by { |item| item[:category] }.sort.to_h do |category, list|
      [category, { dialogues: list.size, dialogues_passed: list.count { |item| item[:pass] }, turns: list.sum { |item| item[:turns] },
                   turns_passed: list.sum { |item| item[:passed] } }]
    end
  end

  # Failed turns per check, a check once per turn.
  def by_reason
    @cases.flat_map { |item| failed_checks(item) }.tally.sort_by { |check, count| [-count, check] }.to_h
  end
end
