# frozen_string_literal: true

class Billing::ClosingDocumentsService
  ESF_DEADLINE_DAYS = 15

  def self.process_counterparty_signature!(invoice, signed_at: Time.current)
    new(invoice: invoice).process_counterparty_signature!(signed_at: signed_at)
  end

  def initialize(invoice:, sigex_client: nil, edo_client: nil, esf_client: nil)
    @invoice = invoice
    @profile = invoice.account&.billing_account_profile
    @sigex_client = sigex_client || Billing::SigexClient.new
    @edo_client = edo_client || Billing::UchetEdoClient.new
    @esf_client = esf_client || Billing::IsEsfClient.new
  end

  def send_eavr!
    return @invoice if @invoice.edo_document_id.present?

    unless Billing::Config.closing_documents_configured?
      @invoice.update!(edo_status: 'pending_configuration')
      return @invoice
    end

    customer_bin = resolve_and_backfill_customer_bin!
    return record_missing_customer_bin! if customer_bin.blank?

    sign_and_send_eavr!(customer_bin)
  end

  def process_counterparty_signature!(signed_at: Time.current)
    return @invoice if @invoice.esf_id.present? && @invoice.esf_status == 'issued'

    @invoice.update!(signed_by_counterparty_at: signed_at, edo_status: 'signed')
    unless Billing::Config.closing_documents_configured?
      @invoice.update!(esf_status: 'pending_configuration')
      return @invoice
    end

    turnover_date = clamped_turnover_date(signed_at)
    return handle_esf_deadline_exceeded!(turnover_date) if (Billing.today_almaty - turnover_date).to_i > ESF_DEADLINE_DAYS

    issue_signed_esf!(turnover_date)
  end

  private

  def sign_and_send_eavr!(customer_bin)
    payload = build_eavr_payload(customer_bin)
    signed = @sigex_client.sign_payload!(payload)
    edo_res = @edo_client.send_eavr!(eavr_payload: payload, cms_signature: signed[:cms_signature])
    @invoice.update!(
      edo_document_id: edo_res[:document_id],
      edo_status: 'sent_for_signature',
      metadata: @invoice.metadata.merge('eavr_sent_at' => Time.current.iso8601)
    )
    @invoice
  rescue Billing::SigexClient::ApiError, Billing::UchetEdoClient::ApiError => e
    @invoice.update!(
      edo_status: 'failed',
      metadata: @invoice.metadata.merge('edo_last_error' => e.message, 'edo_failed_at' => Time.current.iso8601)
    )
    raise
  end

  def issue_signed_esf!(turnover_date)
    customer_bin = resolve_and_backfill_customer_bin! || @invoice.payer_tax_id
    esf_payload = build_esf_payload(turnover_date, customer_bin)
    signed = @sigex_client.sign_payload!(esf_payload)
    esf_res = @esf_client.issue_esf!(esf_payload: esf_payload, cms_signature: signed[:cms_signature])
    @invoice.update!(esf_id: esf_res[:esf_id], esf_status: 'issued', metadata: esf_issued_metadata(turnover_date))
    @invoice
  rescue Billing::SigexClient::ApiError, Billing::IsEsfClient::ApiError => e
    @invoice.update!(
      esf_status: 'failed',
      metadata: @invoice.metadata.merge('esf_last_error' => e.message, 'esf_failed_at' => Time.current.iso8601)
    )
    raise
  end

  def esf_issued_metadata(turnover_date)
    @invoice.metadata.merge(
      'esf_issued_at' => Time.current.iso8601,
      'esf_turnover_date' => turnover_date.iso8601,
      'esf_statutory_deadline_on' => (turnover_date + ESF_DEADLINE_DAYS.days).iso8601
    )
  end

  def clamped_turnover_date(signed_at)
    raw_date = signed_at.in_time_zone(Billing::ALMATY_TIMEZONE).to_date
    [raw_date, Billing.today_almaty].min
  end

  def resolve_and_backfill_customer_bin!
    bin = Billing.normalize_tax_id(@invoice.payer_tax_id) || Billing.normalize_tax_id(@profile&.effective_tax_id)
    return nil if bin.blank?

    @invoice.update!(payer_tax_id: bin) if @invoice.payer_tax_id.blank?
    bin
  end

  def record_missing_customer_bin!
    @invoice.update!(
      edo_status: 'failed',
      metadata: @invoice.metadata.merge('edo_last_error' => 'Missing customer BIN/IIN')
    )
    Billing::OwnerTaskService.new.create_idempotent_task!(
      idempotency_key: "billing:edo_missing_bin:#{@invoice.invoice_number}",
      title: "[АВР не отправлен: нет БИН] Счёт #{@invoice.invoice_number}",
      description: "У клиники Account ##{@invoice.account_id} не заполнен БИН/ИИН для отправки ЭАВР."
    )
    @invoice
  end

  def handle_esf_deadline_exceeded!(turnover_date)
    deadline_on = turnover_date + ESF_DEADLINE_DAYS.days
    @invoice.update!(
      esf_status: 'deadline_exceeded',
      metadata: @invoice.metadata.merge('esf_statutory_deadline_on' => deadline_on.iso8601)
    )
    Billing::OwnerTaskService.new.create_idempotent_task!(
      idempotency_key: "billing:esf_deadline:#{@invoice.invoice_number}",
      title: "[Срок ЭСФ 15 дн. истёк] Счёт #{@invoice.invoice_number}",
      description: "Дата оборота (подписания АВР): #{turnover_date.strftime('%d.%m.%Y')}, крайний срок ЭСФ: #{deadline_on.strftime('%d.%m.%Y')}."
    )
    @invoice
  end

  def build_eavr_payload(customer_bin)
    {
      document_type: 'EAVR',
      invoice_number: @invoice.invoice_number,
      contract_number: @profile&.effective_contract_number || 'Оферта OneLink',
      supplier_bin: Billing::Config.bcc_supplier_bin,
      supplier_name: Billing::Config.bcc_supplier_name,
      supplier_iban: Billing::Config.bcc_business_iban,
      supplier_bik: Billing::Config.bcc_supplier_bik,
      customer_bin: customer_bin,
      customer_name: @invoice.payer_legal_name || @profile&.effective_legal_name,
      currency: @invoice.currency,
      total_amount_kzt: @invoice.amount_kzt.to_s('F'),
      vat_exempt: true,
      items: serialized_items_kzt
    }
  end

  def build_esf_payload(turnover_date, customer_bin)
    build_eavr_payload(customer_bin).merge(
      document_type: 'ESF',
      eavr_document_id: @invoice.edo_document_id,
      turnover_date: turnover_date.iso8601
    )
  end

  def serialized_items_kzt
    Array(@invoice.line_items).map do |item|
      {
        description: item['description'],
        quantity: item['quantity'],
        unit_price_kzt: Billing.minor_to_kzt(item['unit_price_minor']).to_s('F'),
        amount_kzt: Billing.minor_to_kzt(item['amount_minor']).to_s('F'),
        vat_rate: 'WITHOUT_VAT'
      }
    end
  end
end
