# frozen_string_literal: true

# Judges again, without running an agent, the turns of a stored report whose rubric judge gave no verdict (judge_unavailable or
# judge_invalid_json: a warning of the turn and `judge.unusable` in a report of today, a failure in an older one); with `all: true`,
# every judged turn. Everything the judge reads is in the report or in the fixture the case names:
# the reply, the tool calls and the database changes of the turn are stored with the case; the rubric and the facts of the workspace come
# from the fixture (as it is now: a turn whose customer text no longer matches is refused); the transcript is rebuilt from the earlier
# turns of the dialogue, the way the runner records it (what the customer wrote and the replies the customer saw).
#
# The new verdict replaces the old judge failure of the turn. Every other failure of the turn stays. The summary, the gate and the triage
# list are computed again from the new cases. Only the judge calls cost money, and they stop at `budget_usd`; a turn left unjudged keeps
# its old case.
class Captain::Evals::RoutingBenchmark::Rejudge
  UNUSABLE = Captain::Evals::RoutingBenchmark::Scorer::JUDGE_UNUSABLE
  JUDGE_CHECKS = (UNUSABLE + %w[judge_failed]).freeze

  Result = Struct.new(:report, :rejudged, :cost_usd, :stopped, keyword_init: true)

  # Judges with a throwaway account of its own (rolled back at the end, like every workspace of the benchmark): the judge needs an
  # account for its key and its budget check, and the run leaves nothing behind.
  def self.run(report, budget_usd:, **options)
    runner = Captain::Evals::RoutingBenchmark::Runner.new(fixtures: 'rejudge', runs: 1, budget_usd: budget_usd, out: 'rejudge', judge: true)
    connection = ActiveRecord::Base.connection
    connection.begin_transaction(joinable: false, _lazy: false)
    begin
      account = Account.create!(name: "Rejudge #{SecureRandom.uuid}", locale: 'ru', internal_attributes: { 'captain_benchmark_source' => true })
      new(report, runner: runner, account: account, budget_usd: budget_usd, **options).call
    ensure
      connection.rollback_transaction
    end
  end

  # fixture_paths: files that stand in for a fixture a case names when that path no longer exists (matched by file name).
  def initialize(report, runner:, account:, budget_usd:, all: false, fixture_paths: [], labels: {})
    @report = report.deep_stringify_keys
    @runner, @account, @budget_usd = runner, account, BigDecimal(budget_usd.to_s)
    @all, @fixture_paths, @labels = all, Array(fixture_paths), labels
    @fixtures = {}
    @spent = BigDecimal('0')
    @rejudged = 0
  end

  def call
    cases = @report.fetch('cases')
    rows = cases.each_with_index.map { |row, index| redo?(row) ? rejudge(row, cases.first(index)) : row }
    Result.new(report: rebuilt(rows), rejudged: @rejudged, cost_usd: @spent.to_f, stopped: @stopped)
  end

  private

  def redo?(row)
    @all ? judged_before?(row) : unusable_before?(row)
  end

  # The judge gave no verdict: the turn says so (`judge.unusable`), or an older report holds it as a failure.
  def unusable_before?(row)
    row.dig('judge', 'unusable').present? || row.fetch('failures', []).any? { |failure| UNUSABLE.include?(failure['check']) }
  end

  def judged_before?(row)
    row['judge'].present? || row.fetch('failures', []).any? { |failure| JUDGE_CHECKS.include?(failure['check']) }
  end

  def rejudge(row, earlier)
    return row if @stopped
    return stop('budget_reached', row) if @spent >= @budget_usd

    fixture = fixture_for(row)
    dialogue, turn = locate(fixture, row)
    judged, cost = @runner.judge_stored(@account, fixture, dialogue, turn, { 'response' => row['reply'].to_s }, without_judgment(row),
                                        history_for(row, earlier), row.fetch('tool_calls', []).map(&:deep_symbolize_keys),
                                        earlier_handoffs: earlier_handoffs(row, earlier))
    return row unless judged

    @spent += cost
    @rejudged += 1
    row.except('judge', 'not_evaluated').merge(judged.slice(:status, :reasons, :failures, :evaluated, :judge, :warnings, :not_evaluated).deep_stringify_keys)
  rescue Captain::Evals::RoutingBenchmark::Runner::BudgetExceeded => e
    stop(e.message, row)
  end

  def stop(reason, row)
    @stopped = reason
    row
  end

  # The scored turn as it was before the judge: its judge failure (and verdict) removed, the status that follows from the rest.
  def without_judgment(row)
    scored = row.deep_symbolize_keys.except(:judge, :not_evaluated)
    failures = scored.fetch(:failures, []).reject { |failure| JUDGE_CHECKS.include?(failure[:check]) }
    scored.merge(failures: failures, status: failures.empty? ? 'pass' : 'fail',
                 reasons: scored.fetch(:reasons, []).reject { |reason| judge_reason?(reason) },
                 evaluated: scored.fetch(:evaluated, []).reject { |check| judge_reason?(check) },
                 warnings: scored.fetch(:warnings, []).reject { |warning| UNUSABLE.include?(warning) })
  end

  def judge_reason?(reason) = JUDGE_CHECKS.include?(Captain::Evals::RoutingBenchmark::Scorer.base_check(reason))

  # How often the conversation was handed to staff in the earlier turns of this dialogue and run (the judge is told, as it is in a live run).
  def earlier_handoffs(row, earlier)
    key = row.values_at('fixture', 'dialogue', 'run')
    earlier.count { |item| item.values_at('fixture', 'dialogue', 'run') == key && item.dig('handoff', 'observed') }
  end

  # The history of the runner at that turn: each earlier turn of the dialogue in this run (its customer text, and the reply when the
  # customer saw one), then the customer text of this turn.
  def history_for(row, earlier)
    key = row.values_at('fixture', 'dialogue', 'run')
    messages = earlier.select { |item| item.values_at('fixture', 'dialogue', 'run') == key }.flat_map do |item|
      [{ role: 'user', content: item['customer'].to_s }] + seen_reply(item)
    end
    messages << { role: 'user', content: row['customer'].to_s }
  end

  # Runner#public_reply: no reply to the customer for a silent turn, a suppressed reply or a technical failure.
  def seen_reply(item)
    flags = item['response_flags'] || {}
    return [] if item['patient_text'].blank? || flags['response_mode'] == 'suppress' || flags['technical_failure'].present?

    [{ role: 'assistant', content: item['reply'].to_s }]
  end

  def fixture_for(row)
    path = row['fixture'].to_s
    @fixtures[path] ||= Captain::Evals::RoutingBenchmark::Fixture.load(resolve(path))
  end

  def resolve(path)
    return path if File.exist?(path)

    @fixture_paths.find { |candidate| File.basename(candidate) == File.basename(path) } ||
      raise(ArgumentError, "Fixture file not found: #{path} (pass FIXTURES=glob with a copy of it)")
  end

  def locate(fixture, row)
    dialogue = fixture.dialogues.find { |item| item['id'] == row['dialogue'] }
    turn = dialogue && dialogue.fetch('turns', [])[row['turn'].to_i - 1]
    unless turn && turn['customer'].to_s == row['customer'].to_s
      raise ArgumentError, "The fixture no longer matches the report: #{File.basename(row['fixture'].to_s)} #{row['dialogue']} turn #{row['turn']}"
    end

    [dialogue, turn]
  end

  def rebuilt(rows)
    summary = Captain::Evals::RoutingBenchmark::Summary.call(rows)
    gate = Captain::Evals::RoutingBenchmark::Gate.for_report(@report.merge('cases' => rows), labels: @labels)
    council_reasons = Captain::Evals::RoutingBenchmark::Scorer::COUNCIL_REASONS
    aggregates = @report.fetch('aggregates', {}).merge(
      summary.except(:dialogue_summaries).deep_stringify_keys,
      'passed' => rows.count { |row| row['status'] == 'pass' },
      'not_evaluated' => rows.count { |row| row['status'] == 'not_evaluated' },
      'passed_ignoring_council_signal' => rows.count { |row| row['status'] != 'not_evaluated' && (row['reasons'] - council_reasons).empty? }
    )
    @report.merge('cases' => rows, 'gate' => gate, 'triage' => Captain::Evals::RoutingBenchmark::Triage.records(rows, labels: @labels),
                  'needs_review' => Captain::Evals::RoutingBenchmark::Review.records(rows),
                  'aggregates' => aggregates, 'dialogue_summaries' => summary[:dialogue_summaries],
                  'rejudge' => { 'turns' => @rejudged, 'cost_usd' => @spent.to_f, 'all' => @all, 'stopped' => @stopped }.compact)
  end
end
