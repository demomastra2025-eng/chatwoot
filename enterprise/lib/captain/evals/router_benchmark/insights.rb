# frozen_string_literal: true

# The release questions of a router benchmark run that the plain accuracy does not answer (part of
# Captain::Evals::RouterBenchmark::Report):
#   traps          accuracy on the trap scenarios (the "trap" tag of a scenario: human, injection, false_council), which must all pass
#   wrong_answers  how many wrong answers had a low confidence (below 0.75, 0.80 for staff: the probability of the route_mode key
#                  that decided) and how many were confident; the router uses both as they are (no threshold since 26.10)
#   answered_by    for the production pipeline: which model of the chain gave the answer
class Captain::Evals::RouterBenchmark::Insights
  LOW_CONFIDENCE = 0.75
  HUMAN_LOW_CONFIDENCE = 0.80

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
    low = wrong.count { |row| low_confidence?(row) }
    { count: wrong.size, low_confidence: low, confident: wrong.size - low }
  end

  def answered_by
    @rows.map { |row| row.error ? "failed:#{row.error}" : "#{row.decided_by || row.model} (position #{row.chain_position || '-'})" }.tally
  end

  private

  def correct?(row) = row.got == row.expected

  def low_confidence?(row)
    threshold = row.got == 'human_handoff' ? HUMAN_LOW_CONFIDENCE : LOW_CONFIDENCE
    !row.confidence.is_a?(Numeric) || row.confidence < threshold
  end

  def failures(rows)
    rows.reject { |row| correct?(row) }.map { |row| "#{row.scenario_id}: #{row.expected} -> #{row.got || row.error}" }
  end

  def ratio(part, whole)
    whole.to_f.positive? ? (part.to_f / whole).round(4) : nil
  end
end
