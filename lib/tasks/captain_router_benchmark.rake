# frozen_string_literal: true

# The evaluation harness of the decision router (see Captain::Evals::RouterBenchmark): real calls to OpenRouter, no database
# fixtures. Every scenario is routed by the same RoutingSnapshot, questions (route_mode + include_agent_<id>) and DecisionRouter
# the live runtime uses. MODELS asks each listed decision model alone (no escalation); CHAIN=1 runs the production pipeline (the
# routing chain CAPTAIN_AGENT_ROUTING_MODELS, built in Perplexity Decider 1.2, then JEV 1.14, then Mercury Decide, plus the
# escalation when ESCALATION=1).
#
#   RAILS_ENV=test bundle exec rake captain:router_benchmark GRAPHS=tmp/clinic_graphs.json \
#     [SCENARIOS=script/captain/router_benchmark/router_scenarios.json] [CARDS=proposed|prod] \
#     [PROPOSALS=config/captain/router_prompt_migration/2026-10-router.yml] \
#     [MODELS=perplexity/pplx-decider-v1.2,typesafe/jev-1.14,inception/mercury-decide] [CHAIN=1] [ESCALATION=1] \
#     [CHAIN_MODELS=inception/mercury-decide,microsoft/microsoft-decision-1,openai/gpt-6-luna-decisions] \
#     [RUNS=3] [ONLY=SZ01,A11] [FAIL_MODELS=perplexity/pplx-decider-v1.2 FAIL_MODE=error|timeout] BUDGET_USD=2 OUT=tmp/router-<date>.json
#
# CHAIN_MODELS runs the pipeline on that chain instead of the platform one. ONLY plays the listed scenario ids. FAIL_MODELS makes
# the listed decision models fail (no call is made; with FAIL_MODE=timeout after the per-call timeout), to show the fallback chain
# at work: the pipeline rows say which model of the chain answered.
#
# A dry check of the inputs without any model call: rake captain:router_benchmark_check GRAPHS=... (prints the card lint).
# rubocop:disable Metrics/BlockLength
namespace :captain do
  router_inputs = lambda do
    Captain::Evals::RouterBenchmark::Fixture.load(
      graphs: ENV.fetch('GRAPHS'),
      scenarios: ENV.fetch('SCENARIOS', Rails.root.join('script/captain/router_benchmark/router_scenarios.json').to_s),
      cards: ENV.fetch('CARDS', 'proposed'),
      proposals: ENV.fetch('PROPOSALS', Rails.root.join('config/captain/router_prompt_migration/2026-10-router.yml').to_s)
    )
  end
  router_lint = lambda do |fixture|
    fixture.suites.to_h do |suite|
      [suite.name, Captain::Routing::CardLint.call(suite.candidates).map { |finding| "#{finding.severity}: #{finding.message}" }]
    end
  end

  desc 'Check the router benchmark inputs and print the card lint, without calling a model: GRAPHS=... [SCENARIOS=...] [CARDS=...]'
  task router_benchmark_check: %i[routing_benchmark_preflight environment] do
    fixture = router_inputs.call
    puts "#{fixture.suites.size} suites, #{fixture.scenario_count} scenarios"
    router_lint.call(fixture).each { |suite, findings| puts(["#{suite}:", *findings.map { |line| "  #{line}" }].join("\n")) }
  end

  desc 'Run the decision router live on the scenarios and report accuracy, councils, calibration, latency and cost (see the file header)'
  task router_benchmark: %i[routing_benchmark_preflight environment] do
    out = ENV.fetch('OUT')
    raise ArgumentError, 'OUT already exists' if File.exist?(out) || File.exist?("#{out}.md")

    Captain::Evals::RoutingBenchmark::Guard.check!
    Captain::Evals::RoutingBenchmark::Guard.restrict_http!
    fixture = router_inputs.call
    # The calls need an account (its key and its budget check): a throwaway one inside a transaction that unpinning rolls back.
    pool = ActiveRecord::Base.connection_pool
    pool.pin_connection!(true)
    Llm::EventSubscriber.install!
    begin
      account = Account.create!(name: "Router benchmark #{SecureRandom.uuid}", locale: 'ru',
                                internal_attributes: { 'captain_benchmark_source' => true })
      runner = Captain::Evals::RouterBenchmark::Runner.new(
        fixture: fixture, account: account,
        options: { models: ENV.fetch('MODELS', '').split(',').map(&:strip).compact_blank, chain: ENV.fetch('CHAIN', '1') == '1',
                   escalation: ENV.fetch('ESCALATION', '1') == '1', runs: ENV.fetch('RUNS', 1), budget_usd: ENV.fetch('BUDGET_USD'),
                   only: ENV.fetch('ONLY', '').split(',').map(&:strip).compact_blank,
                   chain_models: ENV.fetch('CHAIN_MODELS', '').split(',').map(&:strip).compact_blank,
                   fail_models: ENV.fetch('FAIL_MODELS', '').split(',').map(&:strip).compact_blank,
                   fail_mode: ENV.fetch('FAIL_MODE', 'error'), progress: $stdout }
      )
      rows = runner.call
      report = Captain::Evals::RouterBenchmark::Report.new(rows, fixture: fixture, lint: router_lint.call(fixture))
      File.open(out, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(JSON.pretty_generate(report.to_h.merge(rows: rows.map(&:to_h), spent_usd: runner.spent.to_f)))
      end
      File.open("#{out}.md", File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(report.markdown) }
      puts report.markdown
      puts "\nSpent: #{runner.spent.to_f.round(4)} USD"
    ensure
      pool.unpin_connection!
    end
  end
end
# rubocop:enable Metrics/BlockLength
