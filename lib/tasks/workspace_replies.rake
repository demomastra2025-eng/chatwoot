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

  desc 'Activate an inspected account; optional private CONFIG_PATH resolves conflicts, retired columns are preserved'
  task migrate: :environment do
    account = Account.find(ENV.fetch('ACCOUNT_ID'))
    configs = JSON.parse(File.read(ENV['CONFIG_PATH'])) if ENV['CONFIG_PATH'].present?
    Accounts::WorkspaceRepliesMigration.new(account).apply!(expected_digest: ENV.fetch('EXPECTED_DIGEST'), configs: configs)
    puts "Company replies activated for account #{account.id}"
  rescue JSON::ParserError
    abort 'CONFIG_PATH must contain a valid JSON object with the pending common reply settings'
  rescue ActiveRecord::RecordInvalid => e
    abort "Invalid company reply configuration: #{e.record.errors.attribute_names.join(', ')}"
  end
end
