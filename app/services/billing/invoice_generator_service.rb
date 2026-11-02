# frozen_string_literal: true

class Billing::InvoiceGeneratorService
  MAX_NUMBER_RETRIES = 5

  def initialize(account:, period_start: nil, due_on: nil, usage_period_month: nil, notify: true)
    @account = account
    @requested_period_start = period_start
    @requested_due_on = due_on
    @usage_period_month = usage_period_month
    @notify = notify
  end

  def perform(automatic_through: nil)
    @automatic_through = automatic_through
    invoice = create_locked_invoice!
    return unless invoice

    self.class.resume!(invoice)
  rescue ActiveRecord::RecordNotUnique
    invoice = find_active_period_invoice
    raise unless invoice

    self.class.resume!(invoice)
  end

  def self.resume!(invoice)
    service = new(account: invoice.account, period_start: invoice.period_start)
    service.send(:complete_invoice!, invoice)
  end

  private

  def find_active_period_invoice
    Billing::Invoice.where(account_id: @account.id, period_start: @period_start)
                    .where.not(status: 'cancelled')
                    .first
  end

  def create_locked_invoice!
    @account = Account.find(@account.id)
    @account.with_lock('FOR NO KEY UPDATE') do
      return unless load_current_period

      existing = find_active_period_invoice
      return existing if existing
      return if @automatic_through && cancelled_period?

      calc = Billing::InvoiceAmountCalculator.new(
        account: @account, profile: @profile, period_start: @period_start,
        period_end: @period_end, usage_period_month: @usage_period_month
      ).perform
      persist_with_unique_number!(calc)
    end
  end

  def load_current_period
    @profile = fresh_profile
    return false unless @profile

    @period_start = @requested_period_start || @profile.paid_until || Billing.today_almaty
    @period_end = @profile.next_period_end_from(@period_start)
    @due_on = @requested_due_on || @period_start
    true
  end

  def fresh_profile
    if @automatic_through
      Billing::AccountProfile.automatic_periods_through(@automatic_through).find_by(account_id: @account.id)
    else
      Billing::AccountProfile.find_by(account_id: @account.id) || @account.create_billing_account_profile!
    end
  end

  def cancelled_period?
    Billing::Invoice.exists?(account_id: @account.id, period_start: @period_start, status: 'cancelled')
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
      payment_purpose: "Оплата за доступ к платформе OneLink по счёту № #{inv_number} (без НДС)",
      metadata: Billing::CompletionState.invoice_metadata(account: @account, profile: @profile, invoice_number: inv_number, notify: @notify)
    }
  end

  def attach_pdf!(invoice)
    state = Billing::CompletionState.new(invoice)
    return state.hold!('pdf', 'legacy_without_checkpoint') unless state.managed?
    return if invoice.cancelled?
    return state.hold!('pdf', 'missing_document_snapshot') unless pdf_snapshot_present?(state, invoice)
    return state.local!('pdf') { { 'blob_id' => invoice.pdf_file.blob.id } } if invoice.pdf_file.attached?

    prepare_pdf!(invoice, state)
  end

  def pdf_snapshot_present?(state, invoice)
    state.context['document'].is_a?(Hash) && state.context['document']['contract_number'].present? && invoice.payer_legal_name.present?
  end

  def prepare_pdf!(invoice, state)
    raise 'Billing PDF IO requires a committed transaction' if ActiveRecord::Base.connection.open_transactions.positive?

    token = state.claim!('pdf', configured: true, irreversible: false) { !invoice.cancelled? }
    return unless token

    pdf_bytes = Billing::InvoicePdfGenerator.new(invoice: invoice).render
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(pdf_bytes), filename: "#{invoice.invoice_number}.pdf", content_type: 'application/pdf'
    )
    attach_prepared_blob!(invoice, state, token, blob)
  rescue StandardError => e
    state.fail!('pdf', token, error: e, irreversible: false) if token
    raise
  ensure
    blob.purge if blob && !ActiveStorage::Attachment.exists?(blob_id: blob.id)
  end

  def attach_prepared_blob!(invoice, state, token, blob)
    receipt = {}
    state.finish!('pdf', token, receipt: receipt) do
      raise 'Invoice cancelled during PDF preparation' if invoice.cancelled?

      invoice.pdf_file.attach(blob) unless invoice.pdf_file.attached?
      receipt['blob_id'] = invoice.pdf_file.blob.id
    end
  end

  def complete_invoice!(invoice)
    return invoice if invoice.cancelled?

    attach_pdf!(invoice)
    register_external_channels!(invoice)
    Billing::NotificationService.new(invoice: invoice).deliver_invoice_issued!
    invoice.reload
  end

  def register_external_channels!(invoice)
    return unless Billing::Config.autobilling_enabled?

    register_bcc_open_api!(invoice)
    state = Billing::CompletionState.new(invoice)
    return state.block!('payment_url', 'pending_configuration') unless Billing::Config.bcc_ecom_configured?

    state.local!('payment_url') do
      next false unless invoice.open?

      invoice.payment_url ||= Billing::BccEcomClient.new.build_payment_url(invoice)
      { 'payment_url' => invoice.payment_url }
    end
  end

  def register_bcc_open_api!(invoice)
    state = Billing::CompletionState.new(invoice)
    state.external!('bcc_invoice', configured: Billing::Config.bcc_open_api_configured?, receipt_attribute: :bcc_external_invoice_id,
                                   guard: -> { invoice.open? }) do
      document = state.context['document'].to_h
      required = [invoice.payer_tax_id, document['supplier_bin'], document['supplier_iban']]
      raise ArgumentError, 'Missing document snapshot' unless required.all?(&:present?)

      res = Billing::BccOpenApiClient.new.register_invoice(invoice)
      { receipt: res[:external_invoice_id], attributes: { payment_url: res[:payment_url].presence || invoice.payment_url } }
    end
  end
end
