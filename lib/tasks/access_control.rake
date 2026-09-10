namespace :access_control do
  emit_compatibility_report = lambda do |apply|
    batch_size = ENV.fetch('BATCH_SIZE', 100).to_i
    account_id = ENV.fetch('ACCOUNT_ID', nil)
    accounts = account_id.present? ? Account.where(id: account_id) : Account.all
    abort("Account #{account_id} not found") if account_id.present? && !accounts.exists?

    summary = AccessControl::LegacyRoleBackfill.call(accounts: accounts, apply: apply, batch_size: batch_size) do |account_result|
      puts JSON.generate(type: 'account', **account_result.to_h)
    end
    puts JSON.generate(type: 'summary', **summary.to_h)
    abort('AccessRole compatibility run failed') if summary.failed_accounts.positive?
  end

  desc 'Preview or apply AccessRole presets and legacy AccountUser assignments (set APPLY=1 to write)'
  task bootstrap_roles: :environment do
    warn('access_control:bootstrap_roles now uses the batched backfill runner')
    Rake::Task['access_control:backfill_roles'].invoke
  end

  desc 'Report legacy-to-AccessRole parity without writes (optional ACCOUNT_ID, BATCH_SIZE)'
  task compatibility_report: :environment do
    emit_compatibility_report.call(false)
  end

  desc 'Preview or apply batched legacy-to-AccessRole backfill (set APPLY=1; optional ACCOUNT_ID, BATCH_SIZE)'
  task backfill_roles: :environment do
    emit_compatibility_report.call(ENV['APPLY'] == '1')
  end
end
