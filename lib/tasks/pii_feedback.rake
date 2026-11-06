# Read-only operator summary: rake 'pii:feedback[123]' or rake 'pii:feedback[global]'.
namespace :pii do
  desc 'Show aggregate PII feedback counts for an account or explicit global scope'
  task :feedback, [:account_id] => :environment do |_task, args|
    scope = args[:account_id]
    result = Llm::PiiFeedbackMetrics.summary(account_id: scope, global: scope == 'global')
    puts JSON.pretty_generate(result)
  end
end
