namespace :workspace_replies do
  desc 'Read-only release preflight for company replies; never prints message text'
  task preflight: :environment do
    pending = []
    Account.find_each do |account|
      snapshot = Accounts::WorkspaceRepliesMigration.new(account).report
      next if snapshot[:configs].empty?

      pending << { account_id: account.id, digest: snapshot[:digest], conflicts: snapshot[:conflicts] }
    end
    puts JSON.pretty_generate(pending)
    abort 'Company replies require migration before releasing the new runtime' if pending.any?
  end

  desc 'Activate one inspected account using ACCOUNT_ID and EXPECTED_DIGEST; preserves retired columns'
  task migrate: :environment do
    account = Account.find(ENV.fetch('ACCOUNT_ID'))
    Accounts::WorkspaceRepliesMigration.new(account).apply!(expected_digest: ENV.fetch('EXPECTED_DIGEST'))
    puts "Company replies activated for account #{account.id}"
  end
end
