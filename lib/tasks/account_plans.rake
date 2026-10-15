# Read-only report of what the account plans would change. It never writes.
#
#   rake accounts:plan_report                # every account
#   rake accounts:plan_report ACCOUNT_ID=12  # one account
namespace :accounts do
  desc 'Read-only: per account, what applying the base plan + the modules it already uses would enable, disable and change in the limits'
  task plan_report: :environment do
    scope = ENV['ACCOUNT_ID'].present? ? Account.where(id: ENV.fetch('ACCOUNT_ID')) : Account.all
    puts Accounts::PlanReport.new(scope).to_text
  end
end
