# frozen_string_literal: true

class Billing::PaymentEvent < ApplicationRecord
  SOURCES = %w[bcc_open_api bcc_ecom manual].freeze
  STATUSES = %w[matched needs_review ignored].freeze

  belongs_to :billing_invoice, class_name: 'Billing::Invoice', optional: true, inverse_of: :payment_events
  belongs_to :account, optional: true, inverse_of: :billing_payment_events

  before_validation :normalize_attributes

  validates :bank_reference_id, presence: true, uniqueness: { scope: :source }
  validates :source, inclusion: { in: SOURCES }
  validates :status, inclusion: { in: STATUSES }
  validates :currency, presence: true
  validates :amount_minor, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  def amount_kzt
    Billing.minor_to_kzt(amount_minor)
  end

  private

  def normalize_attributes
    self.currency = currency.to_s.strip.upcase.presence || Billing::DEFAULT_CURRENCY
    self.sender_tax_id = Billing.normalize_tax_id(sender_tax_id)
  end
end
