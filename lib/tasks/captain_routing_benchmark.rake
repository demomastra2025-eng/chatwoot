# frozen_string_literal: true

namespace :captain do
  task :routing_benchmark_preflight do
    raise 'Production is forbidden' if %w[RAILS_ENV RACK_ENV].any? { |key| ENV[key] == 'production' }
  end

  desc 'Run isolated Captain routing benchmarks against the real agent runtime'
  task routing_benchmark: %i[routing_benchmark_preflight environment] do
    # Each dialogue lives in an uncommitted, rolled-back transaction, so everything that runs on another thread would have to share
    # its connection (as transactional specs do) or it could not see the synthetic workspace. The pinned connection opens an outer
    # transaction that unpinning rolls back. A thread that opens a transaction of its own on the pinned connection deadlocks, so
    # the council runs all its parts on the calling thread, in plan order (the read-only lanes would otherwise use threads) unless
    # the switch is set on purpose. The scorer reads the events of the whole turn window (every LlmEvent after the turn started,
    # whatever its request id), so parallel parts would not be missed either; the switch stays off by default because of the
    # deadlock.
    ENV['CAPTAIN_COUNCIL_PARALLEL'] ||= 'off'
    pool = ActiveRecord::Base.connection_pool
    pool.pin_connection!(true)
    # The benchmark runs with RAILS_ENV=test, where the LLM event subscriber is not installed by default.
    # Tool calls, council events and provider cost (the budget cap) are all read from recorded LlmEvent rows.
    Llm::EventSubscriber.install!
    begin
      Captain::Evals::RoutingBenchmark::Runner.new(
        fixtures: ENV.fetch('FIXTURES'), runs: ENV.fetch('RUNS', 3),
        model: ENV.fetch('MODEL', 'openai/gpt-6-luna'), reasoning: ENV.fetch('REASONING', 'none'),
        budget_usd: ENV.fetch('BUDGET_USD'), out: ENV.fetch('OUT'), judge: ENV['JUDGE'] == '1', triage: ENV['TRIAGE'].presence,
        progress: $stdout
      ).call
    ensure
      pool.unpin_connection!
    end
  end

  desc 'Load the fixtures strictly and list what they lack for gate items a and f and what the calendar lint finds, without calling a ' \
       'model: FIXTURES=glob (exit 1 unless nothing is missing)'
  task routing_benchmark_fixtures: %i[routing_benchmark_preflight environment] do
    paths = Dir.glob(ENV.fetch('FIXTURES'))
    raise ArgumentError, 'No fixtures matched FIXTURES' if paths.empty?

    begin
      audit = Captain::Evals::RoutingBenchmark::FixtureAudit.load(paths)
    rescue Captain::Evals::RoutingBenchmark::Fixture::Invalid => e
      puts "Invalid fixture: #{e.message}"
      exit(1)
    end
    puts audit.markdown
    exit(1) unless audit.ok?
  end

  desc 'Compare two routing benchmark outputs: FIRST=a.json SECOND=b.json [OUT=comparison.json] (exit 1 unless similar and both pass the gate)'
  task routing_benchmark_compare: %i[routing_benchmark_preflight environment] do
    first = Captain::Evals::RoutingBenchmark::Compare.load(ENV.fetch('FIRST'))
    second = Captain::Evals::RoutingBenchmark::Compare.load(ENV.fetch('SECOND'))
    comparison = Captain::Evals::RoutingBenchmark::Compare.new(first, second)
    puts comparison.markdown
    if ENV['OUT'].present?
      raise ArgumentError, 'OUT already exists' if File.exist?(ENV['OUT']) || File.exist?("#{ENV['OUT']}.md")

      File.write(ENV['OUT'], JSON.pretty_generate(comparison.result), perm: 0o600)
      File.write("#{ENV['OUT']}.md", comparison.markdown, perm: 0o600)
    end
    # Gate item 3: two similar runs that both pass the gate. Two runs with the same critical failures are similar, too.
    exit(1) unless comparison.result[:gate_item_3]
  end

  desc 'Judge again the turns of a stored report whose judge gave no verdict, without running the agents (only the judge calls cost money): ' \
       'REPORT=out.json OUT=new.json BUDGET_USD=1 [FIXTURES=glob] [ALL=1 judges every judged turn] [TRIAGE=labels.json]'
  task routing_benchmark_rejudge: %i[routing_benchmark_preflight environment] do
    out = ENV.fetch('OUT')
    raise ArgumentError, 'OUT already exists' if File.exist?(out) || File.exist?("#{out}.md")
    raise ArgumentError, 'OUT directory does not exist' unless File.directory?(File.dirname(out))

    Captain::Evals::RoutingBenchmark::Guard.check!
    Captain::Evals::RoutingBenchmark::Guard.restrict_http!
    report = JSON.parse(File.read(ENV.fetch('REPORT')))
    labels = Captain::Evals::RoutingBenchmark::Triage.load(ENV['TRIAGE'].presence)
    # The judge needs an account (its key and its budget check): it gets one inside a transaction that unpinning rolls back.
    pool = ActiveRecord::Base.connection_pool
    pool.pin_connection!(true)
    Llm::EventSubscriber.install!
    begin
      result = Captain::Evals::RoutingBenchmark::Rejudge.run(
        report, budget_usd: ENV.fetch('BUDGET_USD'), all: ENV['ALL'] == '1', labels: labels,
                fixture_paths: ENV['FIXTURES'].present? ? Dir.glob(ENV['FIXTURES']) : []
      )
    ensure
      pool.unpin_connection!
    end
    File.open(out, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(JSON.pretty_generate(result.report)) }
    File.open("#{out}.md", File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(Captain::Evals::RoutingBenchmark::Report.new(result.report).markdown)
    end
    puts "Judged again: #{result.rejudged} turn(s), cost #{result.cost_usd} USD#{", stopped: #{result.stopped}" if result.stopped}"
    puts "Gate: #{result.report.dig('gate', :verdict) || result.report.dig('gate', 'verdict')}"
  end

  desc 'Print the release gate and the triage list of a routing benchmark output: REPORT=out.json [TRIAGE=labels.json]'
  task routing_benchmark_gate: %i[routing_benchmark_preflight environment] do
    report = JSON.parse(File.read(ENV.fetch('REPORT')))
    labels = Captain::Evals::RoutingBenchmark::Triage.load(ENV['TRIAGE'].presence)
    cases = report.fetch('cases')
    gate = Captain::Evals::RoutingBenchmark::Gate.call(cases, aborted: report['aborted'], abort_reason: report['abort_reason'], labels: labels,
                                                              silent_handoff: report['silent_handoff'],
                                                              silent_handoff_error: report['silent_handoff_error'])
    report['gate'] = gate
    report['triage'] = Captain::Evals::RoutingBenchmark::Triage.records(cases, labels: labels)
    puts Captain::Evals::RoutingBenchmark::Report.new(report).markdown
    exit(1) unless gate[:verdict] == 'PASS'
  end
end
