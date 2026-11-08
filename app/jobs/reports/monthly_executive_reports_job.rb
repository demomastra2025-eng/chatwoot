# frozen_string_literal: true

class Reports::MonthlyExecutiveReportsJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform(target_month: nil)
    Account.where(status: :active).find_each do |account|
      next unless account.feature_enabled?('scheduling') || account.scheduling_appointments.exists?

      Reports::MonthlyExecutiveReportService.new(account: account, target_month: target_month).perform
    rescue StandardError => e
      Rails.logger.error("[MonthlyExecutiveReportsJob] Failed for account #{account.id}: #{e.class}: #{e.message}")
    end
  end
end
