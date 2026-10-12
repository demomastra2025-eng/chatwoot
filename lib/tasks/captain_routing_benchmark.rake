# frozen_string_literal: true

namespace :captain do
  task :routing_benchmark_preflight do
    raise 'Production is forbidden' if %w[RAILS_ENV RACK_ENV].any? { |key| ENV[key] == 'production' }
  end

  desc 'Run isolated Captain routing benchmarks against the real agent runtime'
  task routing_benchmark: %i[routing_benchmark_preflight environment] do
    # Council consultations run in threads. Each dialogue lives in an uncommitted, rolled-back transaction, so the
    # threads must share its connection (as transactional specs do) or they cannot see the synthetic workspace.
    # The pinned connection opens an outer transaction that unpinning rolls back.
    pool = ActiveRecord::Base.connection_pool
    pool.pin_connection!(true)
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
