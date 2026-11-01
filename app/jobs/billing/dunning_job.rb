# frozen_string_literal: true

class Billing::DunningJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    return unless Billing::Config.autobilling_enabled?

    today = Billing.today_almaty
    open_enabled_invoices.find_each do |invoice|
      process_invoice_dunning!(invoice, today)
    rescue StandardError => e
      Rails.logger.error("[Billing::DunningJob] invoice=#{invoice.invoice_number} error: #{e.class}: #{e.message}")
    end
  end

  private

  def open_enabled_invoices
    Billing::Invoice.joins(account: :billing_account_profile)
                    .where(status: Billing::Invoice::OPEN_STATUSES)
                    .where(billing_account_profiles: { billing_enabled: true })
                    .includes(account: :billing_account_profile)
  end

  def process_invoice_dunning!(invoice, today)
    profile = invoice.account&.billing_account_profile
    return unless profile

    if today >= invoice.due_on + 3.days
      escalate_overdue!(invoice, profile)
    elsif !active_autopay_pending?(profile, invoice)
      send_gentle_reminder_if_due!(invoice, today)
    end
  end

  def active_autopay_pending?(profile, invoice)
    profile.autopay_enabled? && profile.bcc_card_token.present? &&
      invoice.recurring_attempts_count < Billing::BccRecurringChargeJob::MAX_ATTEMPTS
  end

  def send_gentle_reminder_if_due!(invoice, today)
    if today == invoice.due_on && %w[t_zero t_plus_3].exclude?(invoice.last_reminder_stage)
      Billing::NotificationService.new(invoice: invoice).deliver_dunning_reminder!(stage: 't_zero')
      invoice.update!(last_reminder_stage: 't_zero')
    elsif today == invoice.due_on - 2.days && invoice.last_reminder_stage.blank?
      Billing::NotificationService.new(invoice: invoice).deliver_dunning_reminder!(stage: 't_minus_2')
      invoice.update!(last_reminder_stage: 't_minus_2')
    end
  end

  def escalate_overdue!(invoice, profile)
    invoice.update!(status: 'overdue', last_reminder_stage: 't_plus_3') unless invoice.overdue? && invoice.last_reminder_stage == 't_plus_3'
    if !profile.payment_overdue_banner? || profile.overdue_invoice_number != invoice.invoice_number
      profile.update!(payment_overdue_banner: true, overdue_invoice_number: invoice.invoice_number)
    end
    create_overdue_owner_task!(invoice, profile)
  end

  def create_overdue_owner_task!(invoice, profile)
    amt_str = format('%<amt>.2f %<cur>s', amt: invoice.amount_kzt, cur: invoice.currency)
    Billing::OwnerTaskService.new.create_idempotent_task!(
      idempotency_key: "billing:overdue:#{invoice.invoice_number}",
      title: "[Просрочка T+3] #{profile.effective_legal_name} · #{invoice.invoice_number} · #{amt_str}",
      description: "Клиника: #{profile.effective_legal_name} (Account ##{invoice.account_id})\n" \
                   "Счёт: #{invoice.invoice_number} от #{invoice.period_start.strftime('%d.%m.%Y')}\n" \
                   "Срок оплаты истёк: #{invoice.due_on.strftime('%d.%m.%Y')} (каналы клиники НЕ отключены).",
      priority: 'high'
    )
  end
end
