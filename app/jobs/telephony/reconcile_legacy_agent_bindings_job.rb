# frozen_string_literal: true

class Telephony::ReconcileLegacyAgentBindingsJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform(account_id = nil)
    return Telephony::LegacyAgentBindingReconciliationService.new.perform if account_id.blank?

    account = Account.find_by(id: account_id)
    return account_not_found_result(account_id) if account.blank?

    Telephony::LegacyAgentBindingReconciliationService.new(account: account).perform
  end

  private

  def account_not_found_result(account_id)
    {
      checked: 0,
      disabled: 0,
      skipped: 0,
      binding_ids: [],
      skip_reasons: {},
      account_id: account_id,
      skipped_reason: 'account_not_found'
    }
  end
end
