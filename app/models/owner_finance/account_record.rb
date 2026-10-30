# frozen_string_literal: true

class OwnerFinance::AccountRecord < ApplicationRecord
  self.table_name = 'owner_finance_accounts'

  ACCOUNT_KINDS = %w[business_bank personal_card_filter cash].freeze
  SCOPES = %w[business personal].freeze

  has_many :transactions,
           class_name: 'OwnerFinance::TransactionRecord',
           inverse_of: :account_record,
           dependent: :nullify

  before_validation :normalize_currency

  validates :name, presence: true
  validates :account_kind, inclusion: { in: ACCOUNT_KINDS }
  validates :scope, inclusion: { in: SCOPES }
  validates :currency, inclusion: { in: OwnerFinance::SUPPORTED_CURRENCIES }

  scope :active, -> { where(active: true) }
  scope :business_liquid, -> { active.where(scope: 'business') }

  def balance_kzt
    OwnerFinance.to_kzt(current_balance, currency)
  end

  private

  def normalize_currency
    self.currency = currency.to_s.strip.upcase.presence || 'KZT'
  end
end
