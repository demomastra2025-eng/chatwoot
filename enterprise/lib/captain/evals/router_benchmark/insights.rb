# frozen_string_literal: true

# The release questions of a router benchmark run that the plain accuracy does not answer (part of
# Captain::Evals::RouterBenchmark::Report):
#   traps          accuracy on the trap scenarios (the "trap" tag of a scenario: human, injection, false_council), which must all pass
#   wrong_answers  how many wrong answers came with a confidence below the routing threshold (they would be escalated) and how many
#                  came confident (they would be used as they are)
#   escalation     for the production pipeline: how often the escalation model decided, its latency, and whether it fixed or broke
#                  the answer of the decision models
#   answered_by    for the production pipeline: which model of the chain (or the escalation) gave the final answer
class Captain::Evals::RouterBenchmark::Insights
  LOW_CONFIDENCE = 0.75

  def initialize(rows)
    @rows = Array(rows)
  end

  def traps
    @rows.select(&:trap).group_by(&:trap).transform_values do |group|
      { count: group.size, accuracy: ratio(group.count { |row| correct?(row) }, group.size), failures: failures(group) }
    end
  end

  def traps_passed?
    @rows.select(&:trap).all? { |row| correct?(row) }
  end

  def wrong_answers
    wrong = @rows.reject { |row| row.error || correct?(row) }
    low = wrong.count { |row| row.confidence.is_a?(Numeric) && row.confidence < LOW_CONFIDENCE }
    missing = wrong.count { |row| !row.confidence.is_a?(Numeric) }
    { count: wrong.size, low_confidence: low, missing_confidence: missing, confident: wrong.size - low - missing,
      low_confidence_share: ratio(low + missing, wrong.size) }
  end

  # fixed: the decision models were wrong and the escalation right; broke: the other way round; still_wrong: both wrong.
  def escalation
    escalated = @rows.select(&:escalated)
    outcomes = escalated.map { |row| [row.first_choice == row.expected, correct?(row)] }.tally
    { fired: escalated.size, rate: ratio(escalated.size, @rows.size), fixed: outcomes.fetch([false, true], 0),
      broke: outcomes.fetch([true, false], 0), still_wrong: outcomes.fetch([false, false], 0),
      latency: latency(escalated.filter_map(&:escalation_ms)) }
  end

  def answered_by
    @rows.map { |row| row.error ? "failed:#{row.error}" : "#{row.decided_by || row.model} (position #{row.chain_position || '-'})" }.tally
  end

  private

  def correct?(row) = row.got == row.expected

  def failures(rows)
    rows.reject { |row| correct?(row) }.map { |row| "#{row.scenario_id}: #{row.expected} -> #{row.got || row.error}" }
  end

  def latency(values)
    values = values.sort
    return {} if values.empty?

    { p50: values[[(values.size * 0.5).ceil - 1, 0].max], p90: values[[(values.size * 0.9).ceil - 1, 0].max], max: values.last }
  end

  def ratio(part, whole)
    whole.to_f.positive? ? (part.to_f / whole).round(4) : nil
  end
end
