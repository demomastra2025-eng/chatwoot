module Scheduling::RangeValidator
  MAX_RANGE_DAYS = 31

  module_function

  def validate!(from:, to:, max_days: MAX_RANGE_DAYS)
    raise ArgumentError, 'from is required' if from.blank?
    raise ArgumentError, 'to is required' if to.blank?
    raise ArgumentError, 'to must be greater than from' if to <= from
    raise ArgumentError, "Date range must be #{max_days} days or less" if (to.to_date - from.to_date).to_i > max_days
  end
end
