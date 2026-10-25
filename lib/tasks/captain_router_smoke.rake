# frozen_string_literal: true

# Post-deploy smoke check of the decision router: one real call per model of the routing chain (CAPTAIN_AGENT_ROUTING_MODELS,
# built in Perplexity Decider 1.2, then Mercury Decide, then Microsoft Decision 1) and one call of the escalation model, on a
# synthetic turn. Prints model, latency and ok/fail per row, never a key or a text; exits 1 when a row failed.
#
#   bundle exec rake captain:router_smoke [ACCOUNT_ID=<id>]
#
# ACCOUNT_ID: the account the calls are made for (its OpenRouter key and budget); by default the account of the first agent.
# The monitoring queries for the router are in script/onelink/DECISION_ROUTER_MONITORING.md.
namespace :captain do
  desc 'Smoke-check the decision router: one real decision per chain model and the escalation model (prints model, latency, ok/fail)'
  task router_smoke: :environment do
    account = if ENV['ACCOUNT_ID'].present?
                Account.find(ENV['ACCOUNT_ID'])
              else
                Captain::Assistant.order(:id).first&.account || abort('No account with an agent: pass ACCOUNT_ID')
              end
    Llm::Config.initialize!
    rows = Captain::Runtime::DecisionRouter::Smoke.new(account: account).call
    puts "Router smoke account_id=#{account.id}"
    rows.each { |row| puts row }
    abort('Router smoke failed') unless Captain::Runtime::DecisionRouter::Smoke.ok?(rows)

    puts 'Router smoke ok'
  end
end
