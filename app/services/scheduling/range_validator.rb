module Scheduling::RangeValidator
  MAX_RANGE_DAYS = 31

  module_function

  # allow_equal lets a caller check one exact moment: to == from is a valid range, a reversed one never is.
  def validate!(from:, to:, max_days: MAX_RANGE_DAYS, allow_equal: false)
    raise ArgumentError, 'from is required' if from.blank?
    raise ArgumentError, 'to is required' if to.blank?
    raise ArgumentError, 'to must be greater than from' if allow_equal ? to < from : to <= from
    raise ArgumentError, "Date range must be #{max_days} days or less" if (to.to_date - from.to_date).to_i > max_days
  end
end
