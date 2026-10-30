# frozen_string_literal: true

class OwnerFinance::Obligation < ApplicationRecord
  ENTRY_KINDS = %w[medelement_commission partner_settlement receivable_debt payable_debt open_invoice_1c].freeze
  STATUSES = %w[open paid cancelled].freeze

  belongs_to :contract, class_name: 'OwnerFinance::Contract', optional: true

  before_validation :normalize_currency

  validates :entry_kind, inclusion: { in: ENTRY_KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :title, presence: true
  validates :amount, numericality: { greater_than_or_equal_to: 0 }
  validates :currency, inclusion: { in: OwnerFinance::SUPPORTED_CURRENCIES }

  scope :open_items, -> { where(status: 'open') }

  def outstanding_amount
    [BigDecimal(amount.to_s) - BigDecimal((paid_amount || 0).to_s), BigDecimal(0)].max.round(2)
  end

  def outstanding_kzt
    OwnerFinance.to_kzt(outstanding_amount, currency)
  end

  private

  def normalize_currency
    self.currency = currency.to_s.strip.upcase.presence || 'KZT'
  end
end
