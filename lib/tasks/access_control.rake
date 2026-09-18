# rubocop:disable Metrics/BlockLength
namespace :access_control do
  emit_transition_error = lambda do |status, message, details = {}|
    puts JSON.generate(type: 'mode_transition', status: status, error: message, **details)
    abort(message)
  end

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

  desc 'Report AccessRole release flags, account modes, and canonical mutation footprint without writes'
  task release_status: :environment do
    status = AccessControl::ReleaseGate.status
    puts JSON.generate(type: 'release_gate', **status.to_h)
    abort('AccessRole release gate configuration is invalid') unless status.valid
  end

  desc 'Transition one account through the guarded AccessRole mode state machine (requires ACCOUNT_ID, TO, APPLY=1)'
  task transition: :environment do
    emit_transition_error.call('invalid_request', 'ACCOUNT_ID is required') if ENV['ACCOUNT_ID'].blank?
    emit_transition_error.call('invalid_request', 'TO is required') if ENV['TO'].blank?
    emit_transition_error.call('invalid_request', 'Set APPLY=1 to change access control mode') unless ENV['APPLY'] == '1'

    account = begin
      Account.find(ENV.fetch('ACCOUNT_ID'))
    rescue ActiveRecord::RecordNotFound => e
      emit_transition_error.call('not_found', e.message, account_id: ENV.fetch('ACCOUNT_ID', nil))
    end
    result = AccessControl::ModeTransition.call(account: account, to: ENV.fetch('TO'))
    payload = result.to_h
    payload[:readiness] = result.readiness&.to_h
    puts JSON.generate(type: 'mode_transition', **payload)
  rescue AccessControl::ModeTransition::NotReady => e
    emit_transition_error.call('not_ready', e.message, readiness: e.readiness.to_h)
  rescue AccessControl::ModeTransition::InvalidTransition => e
    emit_transition_error.call('invalid_transition', e.message)
  end
end
# rubocop:enable Metrics/BlockLength
