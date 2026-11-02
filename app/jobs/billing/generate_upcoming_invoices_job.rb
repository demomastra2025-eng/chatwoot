# frozen_string_literal: true

class Billing::GenerateUpcomingInvoicesJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    return unless Billing::Config.autobilling_enabled?

    resume_managed_rows!
    today = Billing.today_almaty
    profiles = Billing::AccountProfile.automatic_periods_through(today + 5.days)
    ceiling = profiles.maximum(:id)
    profiles.where('id <= ?', ceiling).includes(:account).find_each do |profile|
      next unless profile.account

      Billing::InvoiceGeneratorService.new(account: profile.account).perform(automatic_through: today + 5.days)
    rescue StandardError => e
      Rails.logger.error("[Billing::GenerateUpcomingInvoicesJob] account=#{profile.account_id} failed: #{e.class}: #{e.message}")
    end
  end

  private

  def resume_managed_rows!
    invoices = Billing::CompletionState.unfinished(Billing::Invoice.where.not(status: 'cancelled'))
    ceiling = invoices.maximum(:id)
    invoices.where('id <= ?', ceiling).find_each do |invoice|
      Billing::InvoiceGeneratorService.resume!(invoice)
      Billing::ClosingDocumentsJob.perform_later(invoice.id) if invoice.paid?
    rescue StandardError => e
      Rails.logger.warn("[Billing::GenerateUpcomingInvoicesJob] resume invoice=#{invoice.id} error_class=#{e.class}")
    end
    events = Billing::CompletionState.unfinished(Billing::PaymentEvent.all)
    ceiling = events.maximum(:id)
    events.where('id <= ?', ceiling).find_each do |event|
      Billing::PaymentMatcher.resume!(event)
    rescue StandardError => e
      Rails.logger.warn("[Billing::GenerateUpcomingInvoicesJob] resume event=#{event.id} error_class=#{e.class}")
    end
  end
end
