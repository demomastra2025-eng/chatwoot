class Crm::Appointments::DueDealsJob < ApplicationJob
  queue_as :scheduled_jobs
  BATCH_SIZE = 500

  def perform
    due = ApplicationRecord.transaction do
      deals = Crm::Deal.kept.where(closed_at: nil).where('appointment_automation_next_check_at <= ?', Time.current)
                      .order(:appointment_automation_next_check_at, :id).limit(BATCH_SIZE).lock('FOR UPDATE SKIP LOCKED').to_a
      # An indexed, bounded lease prevents repeated enqueues and recovers a lost worker after five minutes.
      deals.each { |deal| deal.update!(appointment_automation_next_check_at: 5.minutes.from_now) }
      deals.map { |deal| [deal.account_id, deal.id] }
    end
    due.each { |account_id, deal_id| Crm::Appointments::EvaluateDealJob.perform_later(account_id, deal_id) }
  end
end
