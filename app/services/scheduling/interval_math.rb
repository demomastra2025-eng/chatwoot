module Scheduling::IntervalMath
  module_function

  def clip(interval, from:, to:)
    start_at = [interval[0], from].max
    end_at = [interval[1], to].min
    return nil if end_at <= start_at

    [start_at, end_at]
  end

  def subtract(base_intervals, blocked_intervals)
    blocked_intervals.reduce(base_intervals) do |memo, blocked|
      memo.flat_map { |interval| subtract_one(interval, blocked) }
    end
  end

  def subtract_one(interval, blocked)
    interval_start, interval_end = interval
    blocked_start, blocked_end = blocked

    return [interval] if blocked_end <= interval_start || blocked_start >= interval_end

    result = []
    result << [interval_start, blocked_start] if blocked_start > interval_start
    result << [blocked_end, interval_end] if blocked_end < interval_end
    result
  end
end
