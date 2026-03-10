module Scheduling::MinuteRangeValidatable
  extend ActiveSupport::Concern

  included do
    validates :start_minute, presence: true, inclusion: { in: 0..1439 }
    validates :end_minute, presence: true, inclusion: { in: 1..1440 }
    validate :end_minute_after_start_minute
  end

  private

  def end_minute_after_start_minute
    return if start_minute.blank? || end_minute.blank?
    return if end_minute > start_minute

    errors.add(:end_minute, 'must be greater than start_minute')
  end
end
