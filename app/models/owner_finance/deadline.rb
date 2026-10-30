# frozen_string_literal: true

class OwnerFinance::Deadline < ApplicationRecord
  CATEGORIES = %w[hosting client_domain own_domain contract personal].freeze
  PAYER_MODES = %w[us rebill_client client_direct incoming_milestone].freeze
  RECURRENCES = %w[once monthly quarterly yearly].freeze
  STATUSES = %w[active completed archived].freeze

  belongs_to :counterparty, class_name: 'OwnerFinance::Counterparty', optional: true
  belongs_to :contract, class_name: 'OwnerFinance::Contract', optional: true

  before_validation :normalize_remind_days
  before_validation :normalize_currency

  validates :title, presence: true
  validates :category, inclusion: { in: CATEGORIES }
  validates :payer_mode, inclusion: { in: PAYER_MODES }
  validates :recurrence, inclusion: { in: RECURRENCES }
  validates :status, inclusion: { in: STATUSES }
  validates :due_on, presence: true
  validates :currency, inclusion: { in: OwnerFinance::SUPPORTED_CURRENCIES }

  scope :active, -> { where(status: 'active') }

  def amount_kzt
    OwnerFinance.to_kzt(amount, currency)
  end

  def days_left(reference_date = OwnerFinance.today_almaty)
    (due_on - reference_date).to_i
  end

  def urgency(reference_date = OwnerFinance.today_almaty)
    return 'completed' unless status == 'active'

    diff = days_left(reference_date)
    return 'overdue' if diff.negative?
    return 'critical' if diff <= 3
    return 'soon' if diff <= 14

    'normal'
  end

  def advance_or_complete!(reference_date: OwnerFinance.today_almaty)
    return update!(status: 'completed') unless %w[monthly quarterly yearly].include?(recurrence)

    next_due = step_date(due_on)
    next_due = step_date(next_due) while next_due <= reference_date
    reset_for_next_cycle!(next_due)
  end

  private

  def normalize_currency
    self.currency = currency.to_s.strip.upcase.presence || 'KZT'
  end

  def step_date(date)
    case recurrence
    when 'monthly' then date.next_month
    when 'quarterly' then date.advance(months: 3)
    when 'yearly' then date.next_year
    else date
    end
  end

  def reset_for_next_cycle!(next_due)
    update!(due_on: next_due, last_reminded_on: nil, last_reminded_offset: nil, status: 'active')
  end

  def normalize_remind_days
    raw = Array(remind_days.presence || OwnerFinance::DEFAULT_REMIND_DAYS)
    self.remind_days = raw.map(&:to_i).select { |day| day.between?(0, 90) }.uniq.sort.reverse
    self.remind_days = OwnerFinance::DEFAULT_REMIND_DAYS if remind_days.empty?
  end
end
