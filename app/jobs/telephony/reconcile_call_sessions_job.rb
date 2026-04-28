class Telephony::ReconcileCallSessionsJob < ApplicationJob
  queue_as :low

  def perform
    Telephony::CallReconciliationService.new.perform
  end
end
