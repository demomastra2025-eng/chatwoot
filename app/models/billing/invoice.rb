# frozen_string_literal: true

class Billing::Invoice < ApplicationRecord
  STATUSES = %w[issued paid cancelled overdue].freeze
  OPEN_STATUSES = %w[issued overdue].freeze
  EDO_STATUSES = %w[pending_configuration sent_for_signature signed failed].freeze
  ESF_STATUSES = %w[pending_configuration issued deadline_exceeded failed].freeze

  belongs_to :account, inverse_of: :billing_invoices
  has_many :payment_events,
           class_name: 'Billing::PaymentEvent',
           foreign_key: :billing_invoice_id,
           inverse_of: :billing_invoice,
           dependent: :nullify

  has_one_attached :pdf_file

  before_validation :normalize_currency

  validates :invoice_number, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :period_start, :period_end, :due_on, :payment_purpose, :knp_code, presence: true
  validates :currency, presence: true
  validates :amount_minor, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :base_amount_minor, :addons_amount_minor, :ai_dialogs_overage_minor,
            :call_minutes_overage_minor, :partner_commission_base_minor,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :edo_status, inclusion: { in: EDO_STATUSES }, allow_nil: true
  validates :esf_status, inclusion: { in: ESF_STATUSES }, allow_nil: true

  scope :open_invoices, -> { where(status: OPEN_STATUSES) }
  scope :recent, -> { order(period_start: :desc, id: :desc) }

  def open? = OPEN_STATUSES.include?(status)
  def paid? = status == 'paid'
  def cancelled? = status == 'cancelled'
  def overdue? = status == 'overdue'

  def amount_kzt = Billing.minor_to_kzt(amount_minor)
  def base_amount_kzt = Billing.minor_to_kzt(base_amount_minor)
  def addons_amount_kzt = Billing.minor_to_kzt(addons_amount_minor)
  def overage_amount_minor = ai_dialogs_overage_minor.to_i + call_minutes_overage_minor.to_i
  def overage_amount_kzt = Billing.minor_to_kzt(overage_amount_minor)
  def partner_commission_base_kzt = Billing.minor_to_kzt(partner_commission_base_minor)

  def as_api_payload
    core_api_fields.merge(amount_api_fields).merge(document_api_fields)
  end

  private

  def normalize_currency
    self.currency = currency.to_s.strip.upcase.presence || Billing::DEFAULT_CURRENCY
  end

  def core_api_fields
    {
      id: id, account_id: account_id, invoice_number: invoice_number, status: status,
      period_start: period_start&.iso8601, period_end: period_end&.iso8601,
      usage_period_month: usage_period_month, due_on: due_on&.iso8601,
      plan_key: plan_key, payer_tax_id: payer_tax_id, payer_legal_name: payer_legal_name,
      knp_code: knp_code, payment_purpose: payment_purpose, payment_url: payment_url,
      paid_at: paid_at&.iso8601, bank_reference_id: bank_reference_id
    }
  end

  def amount_api_fields
    {
      currency: currency, amount_minor: amount_minor, amount_kzt: amount_kzt.to_f,
      base_amount_minor: base_amount_minor, addons_amount_minor: addons_amount_minor,
      ai_dialogs_overage_count: ai_dialogs_overage_count, ai_dialogs_overage_minor: ai_dialogs_overage_minor,
      call_minutes_overage_count: call_minutes_overage_count, call_minutes_overage_minor: call_minutes_overage_minor,
      partner_commission_base_minor: partner_commission_base_minor, line_items: line_items
    }
  end

  def document_api_fields
    {
      pdf_attached: pdf_file.attached?, edo_document_id: edo_document_id, edo_status: edo_status,
      signed_by_counterparty_at: signed_by_counterparty_at&.iso8601, esf_id: esf_id, esf_status: esf_status,
      created_at: created_at&.iso8601
    }
  end
end
