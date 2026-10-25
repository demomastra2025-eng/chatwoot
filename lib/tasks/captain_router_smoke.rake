# frozen_string_literal: true

# Post-deploy smoke check of the decision router: one real call per model of the routing chain (CAPTAIN_AGENT_ROUTING_MODELS,
# built in Perplexity Decider 1.2, then Mercury Decide, then Microsoft Decision 1) and one call of the escalation model, on a
# synthetic turn. Prints model, latency and ok/fail per row, never a key or a text; exits 1 when a row failed.
#
#   bundle exec rake captain:router_smoke [ACCOUNT_ID=<id>]
#
# By default every account that routes (a channel whose agents give the router two or more candidates, see
# Captain::Runtime::DecisionRouter::Smoke.routed_accounts) is checked with its own OpenRouter key and budget; ACCOUNT_ID checks one
# account. The monitoring queries for the router are in script/onelink/DECISION_ROUTER_MONITORING.md.
namespace :captain do
  desc 'Smoke-check the decision router: one real decision per chain model and the escalation model (prints model, latency, ok/fail)'
  task router_smoke: :environment do
    smoke = Captain::Runtime::DecisionRouter::Smoke
    accounts = ENV['ACCOUNT_ID'].present? ? [Account.find(ENV['ACCOUNT_ID'])] : smoke.routed_accounts
    abort('No account routes among two or more agents: pass ACCOUNT_ID') if accounts.empty?

    Llm::Config.initialize!
    failed = accounts.reject do |account|
      rows = smoke.new(account: account).call
      puts "Router smoke account_id=#{account.id}"
      rows.each { |row| puts row }
      smoke.ok?(rows)
    end
    abort("Router smoke failed for account_id=#{failed.map(&:id).join(',')}") if failed.any?

    puts "Router smoke ok accounts=#{accounts.size}"
  end
end
