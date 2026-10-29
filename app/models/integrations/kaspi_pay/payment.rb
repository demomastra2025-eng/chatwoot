# frozen_string_literal: true

class Integrations::KaspiPay::Payment < ApplicationRecord
  self.table_name = 'kaspi_pay_payments'

  PAYMENT_TYPES = %w[qr invoice].freeze
  STATUSES = %w[pending paid failed cancelled expired refunded partially_refunded lost].freeze

  PAID_PROVIDER_STATUSES = %w[Processed Paid RemotePaymentPaid].freeze
  PENDING_PROVIDER_STATUSES = %w[QrTokenCreated QrTokenScanned PaymentConfirmation Wait RemotePaymentCreated].freeze
  CANCELLED_PROVIDER_STATUSES = %w[CancelledByUser CancelledByExternalSource RemotePaymentCanceled].freeze
  EXPIRED_PROVIDER_STATUSES = %w[QrTokenDiscarded Expired RemotePaymentExpired].freeze
  FAILED_PROVIDER_STATUSES = %w[
    NotConfirmedByUser ProcessingFailed Rejected RemotePaymentRejected
    InsufficientFunds InsufficientFundsError Error
    IrisSrcBlockCode1 IrisSrcBlockCode3 IrisSrcBlockCode9
    IrisDestBlockCode3 IrisDestBlockCode5 IrisDestBlockCode7 IrisDestBlockCode10
  ].freeze

  belongs_to :account
  belongs_to :hook, class_name: 'Integrations::Hook', optional: true
  belongs_to :contact, optional: true
  belongs_to :conversation, optional: true
  belongs_to :appointment, class_name: 'Scheduling::Appointment', optional: true
  belongs_to :crm_deal, class_name: 'Crm::Deal', optional: true
  belongs_to :created_by, class_name: 'User', optional: true

  validates :payment_type, inclusion: { in: PAYMENT_TYPES }
  validates :status, inclusion: { in: STATUSES }
  validates :qr_operation_id, presence: true, uniqueness: { scope: :account_id }
  validates :amount, numericality: { only_integer: true, greater_than: 0 }
  validates :refunded_amount, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :recent, -> { order(created_at: :desc, id: :desc) }
  scope :active_pending, -> { where(status: 'pending') }

  def self.resolve_internal_status(raw_provider_status)
    raw = raw_provider_status.to_s
    return 'pending' if raw.blank? || PENDING_PROVIDER_STATUSES.include?(raw)
    return 'paid' if PAID_PROVIDER_STATUSES.include?(raw)
    return 'cancelled' if CANCELLED_PROVIDER_STATUSES.include?(raw)
    return 'expired' if EXPIRED_PROVIDER_STATUSES.include?(raw)

    'failed'
  end

  def pending?
    status == 'pending'
  end

  def refreshable_manually?
    pending? || (paid_at.nil? && %w[expired lost cancelled].include?(status))
  end

  def paid?
    status == 'paid' || status == 'partially_refunded'
  end

  def refundable_amount
    return 0 unless paid?

    [amount - refunded_amount, 0].max
  end

  def as_api_payload
    identity_payload.merge(financial_payload).merge(timestamps_payload)
  end

  private

  def identity_payload
    {
      id: id,
      account_id: account_id,
      contact_id: contact_id,
      conversation_id: conversation&.display_id,
      appointment_id: appointment_id,
      crm_deal_id: crm_deal_id,
      created_by_id: created_by_id,
      payment_type: payment_type,
      status: status,
      provider_status: provider_status,
      provider_status_desc: provider_status_desc,
      qr_operation_id: qr_operation_id,
      order_number: order_number
    }
  end

  def financial_payload
    {
      amount: amount,
      refunded_amount: refunded_amount,
      refundable_amount: refundable_amount,
      payer_phone_masked: payer_phone_masked,
      comment: comment,
      pay_url: pay_url,
      unified_qr_url: unified_qr_url,
      receipt_url: receipt_url
    }
  end

  def timestamps_payload
    {
      expires_at: expires_at&.iso8601,
      paid_at: paid_at&.iso8601,
      created_at: created_at&.iso8601,
      updated_at: updated_at&.iso8601
    }
  end
end
