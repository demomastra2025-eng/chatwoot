# frozen_string_literal: true

class Billing::ClosingDocumentsService
  ESF_DEADLINE_DAYS = 15

  def self.process_counterparty_signature!(invoice, signed_at: Time.current)
    new(invoice: invoice).process_counterparty_signature!(signed_at: signed_at)
  end

  def initialize(invoice:, sigex_client: nil, edo_client: nil, esf_client: nil)
    @invoice = invoice
    @state = Billing::CompletionState.new(invoice)
    @sigex_client = sigex_client || Billing::SigexClient.new
    @edo_client = edo_client || Billing::UchetEdoClient.new
    @esf_client = esf_client || Billing::IsEsfClient.new
  end

  def send_eavr!
    @state.external!('eavr', configured: Billing::Config.closing_documents_configured?, receipt_attribute: :edo_document_id,
                             attributes: { edo_status: 'sent_for_signature' }, guard: -> { @invoice.paid? }) do
      validate_document_snapshot!
      payload = build_eavr_payload(@invoice.payer_tax_id)
      signed = @sigex_client.sign_payload!(payload)
      result = @edo_client.send_eavr!(eavr_payload: payload, cms_signature: signed.fetch(:cms_signature))
      { receipt: result[:document_id] }
    end
    sync_document_status!('eavr', :edo_status)
    @invoice.reload
  end

  def process_counterparty_signature!(signed_at: Time.current)
    @invoice.reload
    return @invoice if existing_esf_receipt?
    return @invoice unless @invoice.paid?

    record_signature!(signed_at)
    unless @invoice.signed_by_counterparty_at && @invoice.edo_document_id.present?
      @state.block!('esf', 'missing_eavr_receipt')
      return @invoice
    end

    turnover_date = Date.iso8601(@invoice.metadata.fetch('esf_turnover_date'))
    return handle_esf_deadline_exceeded!(turnover_date) if (Billing.today_almaty - turnover_date).to_i > ESF_DEADLINE_DAYS

    issue_signed_esf!(turnover_date)
  end

  private

  def existing_esf_receipt?
    return false if @invoice.esf_id.blank?

    @state.external!('esf', configured: false, receipt_attribute: :esf_id) { raise 'Existing ESF must not be posted' }
    true
  end

  def record_signature!(signed_at)
    @invoice.with_lock do
      next unless @invoice.paid? && @invoice.edo_document_id.present?

      first_signed_at = @invoice.signed_by_counterparty_at || signed_at
      date = @invoice.metadata['esf_turnover_date'] || clamped_turnover_date(first_signed_at).iso8601
      meta = @invoice.metadata.merge('esf_turnover_date' => date,
                                     'esf_statutory_deadline_on' => (Date.iso8601(date) + ESF_DEADLINE_DAYS.days).iso8601)
      @invoice.update!(signed_by_counterparty_at: first_signed_at, edo_status: 'signed', metadata: meta)
    end
  end

  def issue_signed_esf!(turnover_date)
    @state.external!('esf', configured: Billing::Config.closing_documents_configured?, receipt_attribute: :esf_id,
                            attributes: { esf_status: 'issued' }, guard: -> { @invoice.paid? && @invoice.edo_document_id.present? }) do
      validate_document_snapshot!
      esf_payload = build_esf_payload(turnover_date, @invoice.payer_tax_id)
      signed = @sigex_client.sign_payload!(esf_payload)
      result = @esf_client.issue_esf!(esf_payload: esf_payload, cms_signature: signed.fetch(:cms_signature))
      { receipt: result[:esf_id] }
    end
    sync_document_status!('esf', :esf_status)
    @invoice.reload
  end

  def clamped_turnover_date(signed_at)
    raw_date = signed_at.in_time_zone(Billing::ALMATY_TIMEZONE).to_date
    [raw_date, Billing.today_almaty].min
  end

  def validate_document_snapshot!
    document = @state.context['document'].to_h
    required = document.values_at('contract_number', 'supplier_bin', 'supplier_name', 'supplier_iban', 'supplier_bik')
    required += [@invoice.payer_legal_name, @invoice.payer_tax_id&.match?(Billing::TAX_ID_FORMAT)]
    raise ArgumentError, 'Missing document snapshot' unless required.all?(&:present?)
  end

  def sync_document_status!(name, attribute)
    @invoice.with_lock do
      current = @state.step(name)
      status = 'pending_configuration' if current['reason'] == 'pending_configuration'
      status = 'failed' if current['state'] == 'needs_review'
      @invoice.update!(attribute => status) if status
    end
  end

  def handle_esf_deadline_exceeded!(turnover_date)
    deadline_on = turnover_date + ESF_DEADLINE_DAYS.days
    @state.hold!('esf', 'deadline_exceeded')
    @invoice.update!(esf_status: 'deadline_exceeded')
    Billing::OwnerTaskService.new.create_idempotent_task!(
      idempotency_key: "billing:esf_deadline:#{@invoice.invoice_number}",
      title: "[Срок ЭСФ 15 дн. истёк] Счёт #{@invoice.invoice_number}",
      description: "Дата оборота (подписания АВР): #{turnover_date.strftime('%d.%m.%Y')}, крайний срок ЭСФ: #{deadline_on.strftime('%d.%m.%Y')}."
    )
    @invoice
  end

  def build_eavr_payload(customer_bin)
    document = @state.context['document'].to_h
    {
      document_type: 'EAVR',
      invoice_number: @invoice.invoice_number,
      contract_number: document['contract_number'],
      supplier_bin: document['supplier_bin'],
      supplier_name: document['supplier_name'],
      supplier_iban: document['supplier_iban'],
      supplier_bik: document['supplier_bik'],
      customer_bin: customer_bin,
      customer_name: @invoice.payer_legal_name,
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
