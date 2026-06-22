# frozen_string_literal: true

namespace :telephony do
  desc 'Reconcile obsolete account-level Fonoster agent bindings. Usage: bin/rails telephony:reconcile_legacy_agent_bindings[account_id,dry_run]'
  task :reconcile_legacy_agent_bindings, %i[account_id dry_run] => :environment do |_task, args|
    account_id = args[:account_id].presence
    account = Account.find_by(id: account_id) if account_id.present?
    abort("Account #{account_id} not found") if account_id.present? && account.blank?

    dry_run = args[:dry_run].nil? || ActiveModel::Type::Boolean.new.cast(args[:dry_run])

    result = Telephony::LegacyAgentBindingReconciliationService.new(account: account, dry_run: dry_run).perform
    puts JSON.pretty_generate(result.deep_stringify_keys)
  end
end
