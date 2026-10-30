# frozen_string_literal: true

class OwnerFinance::DeadlineReminderSweepJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    OwnerFinance::DeadlineReminderService.new.perform
  end
end
