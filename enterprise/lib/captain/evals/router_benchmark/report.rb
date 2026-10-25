# frozen_string_literal: true

# The metrics of a router benchmark run (JSON and Markdown): accuracy per model, suite and expected kind; councils (exact set,
# participant precision and recall, false and missed councils); staff requests; a kind confusion; calibration by confidence; the
# production pipeline (escalation rate and accuracy, chain fallbacks, failures); latency; cost; agreement across runs; and the
# proposed release gate; the trap scenarios, the confidence of wrong answers and the escalation detail (Insights).
class Captain::Evals::RouterBenchmark::Report
  CONFIDENCE_BINS = [[0.9, 1.01, '>=0.9'], [0.8, 0.9, '0.8-0.9'], [0.75, 0.8, '0.75-0.8'], [0.0, 0.75, '<0.75']].freeze
  GATE = { pipeline_accuracy: 0.95, first_model_p90_ms: 1200, escalation_rate: 0.20 }.freeze
  MUST_PASS = %w[SZ01].freeze
  SINGLE_KINDS = %w[agent stay].freeze
  TABLE_HEADER = ['| model | accuracy | false councils | missed councils | exact councils | human recall | traps | wrong (caught/unsafe) | ' \
                  'p50 ms | p90 ms | errors |', '|---|---|---|---|---|---|---|---|---|---|---|'].freeze

  def initialize(rows, fixture: nil, lint: {})
    @rows = Array(rows)
    @fixture = fixture
    @lint = lint
  end

  def to_h
    pipeline_rows = @rows.select { |row| row.mode == 'pipeline' }
    result = { scenarios: @rows.map(&:scenario_id).uniq.size, runs: @rows.map(&:run).uniq.size, models: model_metrics, card_lint: @lint }
    return result if pipeline_rows.empty?

    result.merge(pipeline: pipeline_metrics(pipeline_rows), gate: gate(pipeline_rows))
  end

  def markdown
    data = to_h
    lines = ['# Router benchmark', '', "Scenarios: #{data[:scenarios]}, runs: #{data[:runs]}", '', *TABLE_HEADER]
    data[:models].each { |model, metrics| lines << metric_row(model, metrics) }
    lines << metric_row('pipeline', data[:pipeline]) if data[:pipeline]
    lines.concat(pipeline_lines(data[:pipeline], data[:gate])) if data[:pipeline]
    lines.concat(lint_lines).join("\n")
  end

  private

  def model_metrics
    @rows.select { |row| row.mode == 'model' }.group_by(&:model).transform_values { |rows| metrics(rows) }
  end

  def metrics(rows)
    insights = Captain::Evals::RouterBenchmark::Insights.new(rows)
    accuracy_metrics(rows).merge(
      traps: insights.traps, traps_passed: insights.traps_passed?, wrong_answers: insights.wrong_answers,
      councils: council_metrics(rows), human: human_metrics(rows), confusion: confusion(rows),
      calibration: calibration(rows.reject(&:error)), errors: rows.count(&:error), latency: latency(rows),
      cost_per_1000: ratio(rows.sum { |row| row.cost_usd.to_f } * 1000, rows.size), stability: stability(rows), failures: failures(rows)
    )
  end

  def accuracy_metrics(rows)
    { accuracy: accuracy(rows), by_kind: rows.group_by { |row| kind(row.expected) }.transform_values { |group| accuracy(group) },
      by_suite: rows.group_by(&:suite).transform_values { |group| accuracy(group) } }
  end

  def failures(rows)
    rows.reject { |row| correct?(row) }.map { |row| "#{row.scenario_id}: #{row.expected} -> #{row.got || row.error}" }
  end

  def pipeline_metrics(rows)
    escalated = rows.select(&:escalated)
    insights = Captain::Evals::RouterBenchmark::Insights.new(rows)
    metrics(rows).merge(
      escalation_rate: ratio(escalated.size, rows.size), escalation_accuracy: accuracy(escalated),
      escalation_agreement: ratio(escalated.count { |row| row.first_choice == row.got }, escalated.size),
      escalation_triggers: rows.filter_map(&:escalation_trigger).tally,
      chain_fallbacks: rows.count { |row| row.chain_position.to_i > 1 }, failures_unavailable: rows.count(&:error),
      escalation_detail: insights.escalation, answered_by: insights.answered_by
    )
  end

  def council_metrics(rows)
    councils = rows.select { |row| kind(row.expected) == 'council' }
    {
      false_council_rate: false_council_rate(rows), missed_council_rate: ratio(councils.count { |row| kind(row.got) != 'council' }, councils.size),
      exact_set_rate: accuracy(councils), participant_precision: participant_precision(rows), participant_recall: participant_recall(councils)
    }
  end

  def false_council_rate(rows)
    single = rows.select { |row| SINGLE_KINDS.include?(kind(row.expected)) }
    ratio(single.count { |row| kind(row.got) == 'council' }, single.size)
  end

  def participant_precision(rows)
    predicted = rows.select { |row| kind(row.got) == 'council' }
    ratio(predicted.sum { |row| shared_ids(row) }, predicted.sum { |row| ids(row.got).size })
  end

  def participant_recall(councils)
    ratio(councils.sum { |row| shared_ids(row) }, councils.sum { |row| ids(row.expected).size })
  end

  def human_metrics(rows)
    expected = rows.select { |row| row.expected == 'human_handoff' }
    predicted = rows.select { |row| row.got == 'human_handoff' }
    { recall: accuracy(expected), precision: ratio(predicted.count { |row| row.expected == 'human_handoff' }, predicted.size),
      false_human: predicted.count { |row| row.expected != 'human_handoff' } }
  end

  def confusion(rows)
    rows.group_by { |row| kind(row.expected) }.transform_values { |group| group.map { |row| kind(row.got) }.tally }
  end

  def calibration(rows)
    bins = CONFIDENCE_BINS.to_h do |low, high, label|
      group = rows.select { |row| row.confidence.is_a?(Numeric) && row.confidence >= low && row.confidence < high }
      [label, { count: group.size, accuracy: accuracy(group) }]
    end
    bins.merge('missing' => { count: rows.count { |row| !row.confidence.is_a?(Numeric) } })
  end

  def latency(rows)
    values = rows.filter_map(&:latency_ms).sort
    return {} if values.empty?

    { p50: percentile(values, 0.5), p90: percentile(values, 0.9), max: values.last }
  end

  def stability(rows)
    groups = rows.group_by(&:scenario_id).values.select { |group| group.size > 1 }
    ratio(groups.count { |group| group.map(&:got).uniq.size == 1 }, groups.size)
  end

  def gate(pipeline_rows)
    metrics = pipeline_metrics(pipeline_rows)
    first_p90 = head_model_p90
    checks = {
      pipeline_accuracy: metrics[:accuracy].to_f >= GATE[:pipeline_accuracy], human_scenarios: all_correct?(metrics, :human),
      traps: metrics[:traps_passed],
      must_pass: pipeline_rows.select { |row| MUST_PASS.include?(row.scenario_id) }.all? { |row| correct?(row) },
      no_false_councils: metrics.dig(:councils, :false_council_rate).to_f.zero?,
      first_model_p90: first_p90.nil? || first_p90 <= GATE[:first_model_p90_ms],
      escalation_rate: metrics[:escalation_rate].to_f <= GATE[:escalation_rate]
    }
    { checks: checks, verdict: checks.values.all? ? 'PASS' : 'FAIL' }
  end

  def all_correct?(metrics, key)
    recall = metrics.dig(key, :recall)
    recall.nil? || recall >= 1
  end

  # The p90 of the head model of the platform chain, when it was measured alone.
  def head_model_p90
    head = Llm::DecisionChain.models.first
    latency(@rows.select { |row| row.mode == 'model' && row.model == head })[:p90]
  rescue StandardError
    nil
  end

  def metric_row(name, metrics)
    councils = metrics[:councils]
    "| #{name} | #{pct(metrics[:accuracy])} | #{pct(councils[:false_council_rate])} | #{pct(councils[:missed_council_rate])} | " \
      "#{pct(councils[:exact_set_rate])} | #{pct(metrics.dig(:human, :recall))} | #{trap_cell(metrics[:traps])} | " \
      "#{wrong_cell(metrics[:wrong_answers])} | #{metrics.dig(:latency, :p50)} | " \
      "#{metrics.dig(:latency, :p90)} | #{metrics[:errors]} |"
  end

  def pipeline_lines(pipeline, gate)
    ['', '## Pipeline', "Escalation rate: #{pct(pipeline[:escalation_rate])}, escalation accuracy: #{pct(pipeline[:escalation_accuracy])}, " \
                        "first model and escalation agree: #{pct(pipeline[:escalation_agreement])}",
     "Triggers: #{pipeline[:escalation_triggers]}", "Chain fallbacks: #{pipeline[:chain_fallbacks]}, unavailable: #{pipeline[:failures_unavailable]}",
     "Escalation detail: #{pipeline[:escalation_detail]}", "Answered by: #{pipeline[:answered_by]}",
     "Failures: #{pipeline[:failures].join('; ').presence || 'none'}", '', "## Gate: #{gate[:verdict]}",
     *gate[:checks].map { |name, passed| "- #{name}: #{passed ? 'pass' : 'FAIL'}" }]
  end

  def lint_lines
    return [] if @lint.blank?

    ['', '## Card lint', *@lint.flat_map { |suite, findings| ["- #{suite}", *Array(findings).map { |finding| "  - #{finding}" }] }]
  end

  def correct?(row) = row.got == row.expected

  def wrong_cell(wrong)
    "#{wrong[:count]} (#{wrong[:inconsistent] + wrong[:low_confidence]}/#{wrong[:unsafe]})"
  end

  def trap_cell(traps)
    traps.to_h.sort.map { |name, trap| "#{name} #{pct(trap[:accuracy])}" }.join(', ').presence || '-'
  end

  def accuracy(rows) = ratio(rows.count { |row| correct?(row) }, rows.size)

  def shared_ids(row) = (ids(row.got) & ids(row.expected)).size

  def kind(key)
    case key.to_s
    when 'stay_current' then 'stay'
    when 'human_handoff' then 'human'
    when /\Aroute_agent_/ then 'agent'
    when /\Acouncil_/ then 'council'
    else 'none'
    end
  end

  def ids(key)
    key.to_s.start_with?('council_') ? key.to_s.scan(/\d+/).map(&:to_i) : []
  end

  def percentile(values, fraction)
    values[[(values.size * fraction).ceil - 1, 0].max]
  end

  def ratio(part, whole)
    whole.to_f.positive? ? (part.to_f / whole).round(4) : nil
  end

  def pct(value)
    value.nil? ? '-' : "#{(value * 100).round(1)}%"
  end
end
