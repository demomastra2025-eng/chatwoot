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
    # the council runs all its parts on the calling thread, in plan order (the read-only lanes would otherwise use threads).
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
        budget_usd: ENV.fetch('BUDGET_USD'), out: ENV.fetch('OUT'), judge: ENV['JUDGE'] == '1'
      ).call
    ensure
      pool.unpin_connection!
    end
  end
end
