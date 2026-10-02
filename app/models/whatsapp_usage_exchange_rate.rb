class WhatsappUsageExchangeRate < ApplicationRecord
  STATUSES = %w[fetching fetched unavailable].freeze
  FETCHED_STATUS = 'fetched'.freeze

  validates :month_start, :requested_date, :status, presence: true
  validates :status, inclusion: { in: STATUSES }
  validate :month_starts_on_first_day
  validate :requested_date_matches_month
  validates :effective_date, :rate_per_usd, :nominal_rate, :nominal_units, :fetched_at, :source_url,
            presence: true, if: :fetched?
  validates :rate_per_usd, :nominal_rate, numericality: { greater_than: 0 }, allow_blank: true, if: :fetched?
  validates :nominal_units, numericality: { only_integer: true, greater_than: 0 }, allow_blank: true, if: :fetched?
  validates :retry_after, :source_url, presence: true, if: :fetching?
  validate :successful_snapshot_is_immutable, on: :update

  def fetched?
    status == FETCHED_STATUS
  end

  def fetching?
    status == 'fetching'
  end

  private

  def month_starts_on_first_day
    return if month_start.blank? || month_start.day == 1

    errors.add(:month_start, 'must be the first day of a month')
  end

  def requested_date_matches_month
    return if month_start.blank? || requested_date.blank? || requested_date == month_start

    errors.add(:requested_date, 'must match the report month start')
  end

  def successful_snapshot_is_immutable
    return unless status_in_database == FETCHED_STATUS

    errors.add(:base, 'A fetched monthly exchange rate snapshot is immutable')
  end
end
