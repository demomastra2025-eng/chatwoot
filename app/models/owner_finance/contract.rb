# frozen_string_literal: true

class OwnerFinance::Contract < ApplicationRecord
  STATUSES = %w[active signed under_termination performed archived].freeze
  LIVE_STATUSES = %w[active signed under_termination].freeze
  TARIFF_CODES = %w[text_voice_99k ai_agent_rop_199k voice_ai_399k custom].freeze

  belongs_to :counterparty, class_name: 'OwnerFinance::Counterparty', optional: true
  has_many :deadlines, class_name: 'OwnerFinance::Deadline', dependent: :destroy
  has_many :obligations, class_name: 'OwnerFinance::Obligation', dependent: :nullify
  has_many :transactions, class_name: 'OwnerFinance::TransactionRecord', dependent: :nullify

  before_validation :normalize_currency

  validates :client_name, presence: true
  validates :title, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :tariff_code, inclusion: { in: TARIFF_CODES }
  validates :currency, inclusion: { in: OwnerFinance::SUPPORTED_CURRENCIES }

  after_save :sync_expiry_deadline!

  scope :live, -> { where(status: LIVE_STATUSES) }

  def monthly_amount_kzt
    OwnerFinance.to_kzt(monthly_amount, currency)
  end

  def medelement_monthly_commission_kzt
    return BigDecimal(0) unless medelement_commission_enabled?

    (monthly_amount_kzt * BigDecimal((medelement_commission_rate || 0.3).to_s)).round(2)
  end

  private

  def normalize_currency
    self.currency = currency.to_s.strip.upcase.presence || 'KZT'
  end

  def sync_expiry_deadline!
    existing = OwnerFinance::Deadline.find_by(external_source_key: "contract_expiry:#{id}")
    return existing&.destroy! if ends_on.blank?

    deadline = existing || OwnerFinance::Deadline.new(external_source_key: "contract_expiry:#{id}")
    attrs = expiry_deadline_attributes
    if deadline.due_on != ends_on
      attrs[:last_reminded_on] = nil
      attrs[:last_reminded_offset] = nil
    end
    deadline.update!(attrs)
  end

  def expiry_deadline_attributes
    {
      title: "Окончание договора: #{client_name} — #{title}",
      category: 'contract', payer_mode: 'client_direct', client_name: client_name,
      counterparty_id: counterparty_id, contract_id: id, due_on: ends_on,
      amount: monthly_amount, currency: currency, recurrence: 'once',
      status: LIVE_STATUSES.include?(status) ? 'active' : 'archived'
    }
  end
end
