# frozen_string_literal: true

class Billing::InvoiceGeneratorService
  MAX_NUMBER_RETRIES = 5

  def initialize(account:, period_start: nil, due_on: nil, usage_period_month: nil, notify: true)
    @account = account
    @profile = account.billing_account_profile || account.create_billing_account_profile!
    @period_start = period_start || @profile.paid_until || Billing.today_almaty
    @period_end = @profile.next_period_end_from(@period_start)
    @due_on = due_on || @period_start
    @usage_period_month = usage_period_month
    @notify = notify
  end

  def perform
    existing = find_active_period_invoice
    return existing if existing

    invoice = create_locked_invoice!
    attach_pdf!(invoice)
    register_external_channels!(invoice)
    Billing::NotificationService.new(invoice: invoice).deliver_invoice_issued! if @notify
    invoice
  rescue ActiveRecord::RecordNotUnique
    find_active_period_invoice || raise
  end

  private

  def find_active_period_invoice
    Billing::Invoice.where(account_id: @account.id, period_start: @period_start)
                    .where.not(status: 'cancelled')
                    .first
  end

  def create_locked_invoice!
    @account.with_lock do
      existing = find_active_period_invoice
      return existing if existing

      calc = Billing::InvoiceAmountCalculator.new(
        account: @account, profile: @profile, period_start: @period_start,
        period_end: @period_end, usage_period_month: @usage_period_month
      ).perform
      persist_with_unique_number!(calc)
    end
  end

  def persist_with_unique_number!(calc)
    attempts = 0
    begin
      attempts += 1
      inv_number = next_invoice_number(attempts - 1)
      Billing::Invoice.transaction(requires_new: true) do
        Billing::Invoice.create!(invoice_attributes(inv_number, calc))
      end
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      retry if attempts < MAX_NUMBER_RETRIES && invoice_number_conflict?(e)
      raise
    end
  end

  def invoice_number_conflict?(error)
    return error.message.include?('invoice_number') if error.is_a?(ActiveRecord::RecordNotUnique)

    error.record.is_a?(Billing::Invoice) && error.record.errors.of_kind?(:invoice_number, :taken)
  end

  def next_invoice_number(attempt_offset = 0)
    prefix = format('OL-%<ym>s-%<acc>04d-', ym: @period_start.strftime('%Y%m'), acc: @account.id)
    last_seq = Billing::Invoice.where(account_id: @account.id)
                               .where('invoice_number LIKE ?', "#{prefix}%")
                               .pluck(:invoice_number)
                               .filter_map { |num| num.delete_prefix(prefix).to_i }
                               .max.to_i
    format('%<prefix>s%<seq>02d', prefix: prefix, seq: last_seq + 1 + attempt_offset)
  end

  def invoice_attributes(inv_number, calc)
    {
      account: @account, invoice_number: inv_number, status: 'issued',
      period_start: @period_start, period_end: @period_end, due_on: @due_on,
      usage_period_month: calc.usage_period_month, currency: Billing::DEFAULT_CURRENCY,
      plan_key: calc.plan_key, base_amount_minor: calc.base_amount_minor,
      addons_amount_minor: calc.addons_amount_minor,
      ai_dialogs_overage_count: calc.ai_dialogs_overage_count,
      ai_dialogs_overage_minor: calc.ai_dialogs_overage_minor,
      call_minutes_overage_count: calc.call_minutes_overage_count,
      call_minutes_overage_minor: calc.call_minutes_overage_minor,
      amount_minor: calc.amount_minor, partner_commission_base_minor: calc.partner_commission_base_minor,
      payer_tax_id: @profile.effective_tax_id, payer_legal_name: @profile.effective_legal_name,
      knp_code: @profile.knp_code, line_items: calc.line_items,
      payment_purpose: "Оплата за доступ к платформе OneLink по счёту № #{inv_number} (без НДС)"
    }
  end

  def attach_pdf!(invoice)
    return if invoice.pdf_file.attached?

    pdf_bytes = Billing::InvoicePdfGenerator.new(invoice: invoice).render
    invoice.pdf_file.attach(
      io: StringIO.new(pdf_bytes),
      filename: "#{invoice.invoice_number}.pdf",
      content_type: 'application/pdf'
    )
  end

  def register_external_channels!(invoice)
    return unless Billing::Config.autobilling_enabled?

    register_bcc_open_api!(invoice) if Billing::Config.bcc_open_api_configured? && invoice.bcc_external_invoice_id.blank?
    return unless Billing::Config.bcc_ecom_configured? && invoice.payment_url.blank?

    invoice.update!(payment_url: Billing::BccEcomClient.new.build_payment_url(invoice))
  end

  def register_bcc_open_api!(invoice)
    res = Billing::BccOpenApiClient.new.register_invoice(invoice)
    invoice.update!(
      bcc_external_invoice_id: res[:external_invoice_id],
      payment_url: res[:payment_url].presence || invoice.payment_url
    )
  rescue Billing::BccOpenApiClient::ApiError => e
    invoice.update!(metadata: invoice.metadata.merge('bcc_register_error' => e.message))
  end
end
