# frozen_string_literal: true

require 'json'

# Compares two benchmark outputs of the same fixtures (the two consecutive runs of the release gate, or a run before and
# after a change): the overall score and the critical result of each, the failed count of every check, and the checks that
# flipped (failed on a turn in one run and passed on it in the other). The runs are `similar` when the overall scores are
# within 2 points and the second run has no critical failure that the first did not have. Gate item 3 (two consecutive
# runs) holds when the runs are similar and both pass the gate.
#
# A check is compared on a turn only when both runs scored the turn and both put the check to it: a run that never ran
# `reply_leak` (an older output) did not "pass" it, and a turn that only one run reached says nothing about the other.
#
# Reports are read by their cases, so an older output (without severities or the gate section) compares as well; the
# severity of a reason then comes from Scorer::CHECKS. The triage decisions written into a report count for its gate.
class Captain::Evals::RoutingBenchmark::Compare
  SIMILAR_POINTS = 2.0

  class << self
    def load(path) = JSON.parse(File.read(path))

    def call(first, second)
      new(first, second).result
    end
  end

  def initialize(first, second)
    @first = side(first)
    @second = side(second)
  end

  def result
    new_critical = compared(@second[:critical_keys] - @first[:critical_keys])
    fixed = compared(@first[:critical_keys] - @second[:critical_keys])
    delta = (@second[:gate][:overall][:pct] - @first[:gate][:overall][:pct]).round(2)
    reasons = similarity_reasons(delta, new_critical)
    both_pass = [@first, @second].all? { |side| side[:gate][:verdict] == 'PASS' }
    {
      similar: reasons.empty?, not_similar_because: reasons, both_pass_the_gate: both_pass, gate_item_3: reasons.empty? && both_pass,
      overall: { first: @first[:gate][:overall], second: @second[:gate][:overall], delta_points: delta },
      critical: { first: critical_summary(@first), second: critical_summary(@second),
                  new_in_second: new_critical.sort, fixed_in_second: fixed.sort },
      infra: { first: @first[:gate][:infra].to_h[:turns].to_i, second: @second[:gate][:infra].to_h[:turns].to_i },
      checks: check_deltas, flipped: flipped, turns_compared: (@first[:turns] & @second[:turns]).size
    }
  end

  # Markdown for the console and the OUT file.
  def markdown
    data = result
    lines = ['# Benchmark comparison', '', "**Similar: #{data[:similar] ? 'yes' : 'no'}**", '']
    lines += data[:not_similar_because].map { |reason| "- #{reason}" } + [''] if data[:not_similar_because].any?
    lines += overall_lines(data) + critical_lines(data) + infra_lines(data) + check_lines(data) + flipped_lines(data)
    "#{lines.join("\n")}\n"
  end

  private

  def side(report)
    report = report.to_h.deep_stringify_keys
    cases = report.fetch('cases')
    labels = Captain::Evals::RoutingBenchmark::Triage.labels_from('triage' => report['triage'])
    gate = Captain::Evals::RoutingBenchmark::Gate.for_report(report, labels: labels)
    failures = cases.flat_map { |item| failed_checks(item) }
    {
      gate: gate, cases: cases, turns: cases.map { |item| turn_key(item) }.uniq,
      failed: failures.to_h { |entry| [entry[:key], entry[:severity]] },
      critical_keys: failures.select { |entry| entry[:severity] == 'critical' }.pluck(:key).uniq,
      evaluated: cases.to_h { |item| [turn_key(item), evaluated_bases(item)] }
    }
  end

  def failed_checks(item)
    Captain::Evals::RoutingBenchmark::Triage.failures_of(item).map do |failure|
      { key: [turn_key(item), Captain::Evals::RoutingBenchmark::Scorer.canonical_id(failure['id'])].join(' '),
        severity: Captain::Evals::RoutingBenchmark::Gate.severity_of(failure) }
    end
  end

  # The checks (reason without its argument) a case was put through, failed ones included.
  def evaluated_bases(item)
    ids = Captain::Evals::RoutingBenchmark::Gate.evaluated_ids(item) | Captain::Evals::RoutingBenchmark::Triage.failures_of(item).pluck('id')
    ids.map { |id| Captain::Evals::RoutingBenchmark::Scorer.base_check(id) }.uniq
  end

  # The keys ("turn check") that both runs can speak about: both scored the turn and both put the check to it.
  def compared(keys)
    keys.select { |key| comparable?(key) }
  end

  def comparable?(key)
    turn, check = key.split(' ', 2)
    base = Captain::Evals::RoutingBenchmark::Scorer.base_check(check)
    [@first, @second].all? { |side| side[:evaluated][turn]&.include?(base) }
  end

  # A turn of a run is the fixture file, the dialogue, the run number and the turn.
  def turn_key(item)
    [File.basename(item['fixture'].to_s), item['dialogue'], "run#{item['run'] || 1}", "t#{item['turn']}"].join('/')
  end

  def similarity_reasons(delta, new_critical)
    reasons = []
    reasons << "overall scores differ by #{delta.abs} points (limit #{SIMILAR_POINTS})" if delta.abs > SIMILAR_POINTS
    reasons << "#{new_critical.size} critical failure(s) appear only in the second run" if new_critical.any?
    reasons
  end

  def critical_summary(side)
    critical = side[:gate][:critical]
    { passed: critical[:passed], total: critical[:total], failed: critical[:failed], verdict: side[:gate][:verdict] }
  end

  # Failed count per check in each run, for the checks that failed in either; largest change first, then by severity.
  def check_deltas
    names = (@first[:gate][:checks].keys | @second[:gate][:checks].keys)
    rows = names.map do |name|
      first = @first[:gate][:checks].dig(name, :failed).to_i
      second = @second[:gate][:checks].dig(name, :failed).to_i
      severity = (@first[:gate][:checks][name] || @second[:gate][:checks][name])[:severity]
      { check: name, severity: severity, first: first, second: second, delta: second - first }
    end
    rows.select { |row| row[:first].positive? || row[:second].positive? }
        .sort_by { |row| [-row[:delta].abs, Captain::Evals::RoutingBenchmark::Triage.severity_rank(row[:severity]), row[:check]] }
  end

  # Turn + check failing in exactly one of the two runs, on turns both runs scored and for checks both runs ran.
  def flipped
    keys = compared(@first[:failed].keys | @second[:failed].keys)
    keys.reject { |key| @first[:failed].key?(key) == @second[:failed].key?(key) }.sort.map do |key|
      turn, check = key.split(' ', 2)
      { turn: turn, check: check, severity: @first[:failed][key] || @second[:failed][key],
        first: @first[:failed].key?(key) ? 'fail' : 'pass', second: @second[:failed].key?(key) ? 'fail' : 'pass' }
    end
  end

  def overall_lines(data)
    first, second = data[:overall].values_at(:first, :second)
    ['## Overall', '',
     "- First: #{first[:passed]}/#{first[:total]} turns (#{first[:pct]}%)",
     "- Second: #{second[:passed]}/#{second[:total]} turns (#{second[:pct]}%)",
     "- Difference: #{data[:overall][:delta_points]} points (similar within #{SIMILAR_POINTS})", '']
  end

  def critical_lines(data)
    first, second = data[:critical].values_at(:first, :second)
    lines = ['## Critical', '',
             "- First: #{first[:passed]}/#{first[:total]} passed, #{first[:failed]} failed (#{first[:verdict]})",
             "- Second: #{second[:passed]}/#{second[:total]} passed, #{second[:failed]} failed (#{second[:verdict]})",
             "- Both runs pass the gate: #{data[:both_pass_the_gate] ? 'yes' : 'no'}",
             "- Gate item 3 (two consecutive runs, similar and both passing): #{data[:gate_item_3] ? 'PASS' : 'FAIL'}"]
    lines += data[:critical][:new_in_second].map { |key| "- New in the second run: #{key}" }
    lines += data[:critical][:fixed_in_second].map { |key| "- Gone in the second run: #{key}" }
    lines << ''
  end

  # Turns that failed on the infrastructure under the agents (a technical handoff, a provider error): a run with more of them is not a
  # worse agent, so they are shown apart from the checks.
  def infra_lines(data)
    return [] unless data[:infra].values.any?(&:positive?)

    ['## Infrastructure failures', '', "- First: #{data[:infra][:first]} turn(s)", "- Second: #{data[:infra][:second]} turn(s)", '']
  end

  def check_lines(data)
    rows = data[:checks].map { |row| "| `#{row[:check]}` | #{row[:severity]} | #{row[:first]} | #{row[:second]} | #{format('%+d', row[:delta])} |" }
    return [] if rows.empty?

    ['## Checks (failed turns)', '', '| Check | Severity | First | Second | Change |', '| --- | --- | --- | --- | --- |'] + rows + ['']
  end

  def flipped_lines(data)
    return ['## Flipped checks', '', 'None.'] if data[:flipped].empty?

    ['## Flipped checks', ''] + data[:flipped].map do |row|
      "- #{row[:turn]} `#{row[:check]}` (#{row[:severity]}): first #{row[:first]}, second #{row[:second]}"
    end
  end
end
