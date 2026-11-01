# frozen_string_literal: true

class Billing::GenerateUpcomingInvoicesJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    return unless Billing::Config.autobilling_enabled?

    target_date = Time.use_zone(Billing::ALMATY_TIMEZONE) { Date.current + 5.days }
    Billing::AccountProfile.enabled.where(paid_until: target_date).includes(:account).find_each do |profile|
      next unless profile.account

      Billing::InvoiceGeneratorService.new(
        account: profile.account,
        period_start: profile.paid_until,
        due_on: profile.paid_until
      ).perform
    rescue StandardError => e
      Rails.logger.error("[Billing::GenerateUpcomingInvoicesJob] account=#{profile.account_id} failed: #{e.class}: #{e.message}")
    end
  end
end
