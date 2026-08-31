class AutoAssignment::PeriodicAssignmentJob < ApplicationJob
  queue_as :scheduled_jobs
  include BillingHelper

  def perform
    Account.find_in_batches do |accounts|
      accounts.each do |account|
        next unless account.feature_enabled?('assignment_v2')

        if should_skip_auto_assignment?(account)
          Rails.logger.info("Skipping auto assignment for account #{account.id}")
          next
        end

        account.inboxes.where(enable_auto_assignment: true).find_in_batches do |inboxes|
          inboxes.each do |inbox|
            next unless inbox.auto_assignment_v2_enabled?

            AutoAssignment::AssignmentJob.enqueue(inbox_id: inbox.id)
          end
        end
      end
    end
  end

  private

  def should_skip_auto_assignment?(account)
    return false unless ChatwootApp.chatwoot_cloud?

    default_plan?(account)
  end
end
