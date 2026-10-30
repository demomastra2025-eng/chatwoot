# frozen_string_literal: true

class OwnerFinance::TransactionRecord < ApplicationRecord
  self.table_name = 'owner_finance_transactions'

  DIRECTIONS = %w[income expense transfer].freeze
  PNL_TREATMENTS = %w[pnl non_pnl expense_refund].freeze
  OFFICIAL_STATUSES = %w[official_1c management].freeze
  REVIEW_STATUSES = %w[confirmed needs_review].freeze

  belongs_to :account_record, class_name: 'OwnerFinance::AccountRecord', optional: true
  belongs_to :counterparty, class_name: 'OwnerFinance::Counterparty', optional: true
  belongs_to :contract, class_name: 'OwnerFinance::Contract', optional: true

  before_validation :normalize_currency
  before_validation :sync_amount_kzt

  validates :occurred_on, presence: true
  validates :direction, inclusion: { in: DIRECTIONS }
  validates :pnl_treatment, inclusion: { in: PNL_TREATMENTS }
  validates :official_status, inclusion: { in: OFFICIAL_STATUSES }
  validates :review_status, inclusion: { in: REVIEW_STATUSES }
  validates :merchant, presence: true
  validates :category, presence: true
  validates :amount, numericality: { greater_than_or_equal_to: 0 }
  validates :currency, inclusion: { in: OwnerFinance::SUPPORTED_CURRENCIES }

  scope :confirmed, -> { where(review_status: 'confirmed') }
  scope :needs_review, -> { where(review_status: 'needs_review') }
  scope :in_pnl, -> { confirmed.where(pnl_treatment: %w[pnl expense_refund]) }

  private

  def normalize_currency
    self.currency = currency.to_s.strip.upcase.presence || 'KZT'
  end

  def sync_amount_kzt
    return if preserve_custom_foreign_kzt?

    self.amount_kzt = OwnerFinance.to_kzt(amount, currency)
  end

  def preserve_custom_foreign_kzt?
    return false if currency == 'KZT' || amount_kzt.blank? || amount_kzt <= 0
    return true if new_record?

    will_save_change_to_amount_kzt? || (!will_save_change_to_amount? && !will_save_change_to_currency?)
  end
end
