# frozen_string_literal: true

class Llm::Monitoring::TimeSeriesSnapshot
  DEFAULT_WINDOW = 30.days
  HOURLY_THRESHOLD = 48.hours
  DAILY_THRESHOLD = 90.days
  PERMITTED_BUCKETS = %w[hour day week].freeze

  def initialize(scope: LlmEvent.all, date_range: nil, timezone: nil)
    @scope = scope.respond_to?(:except) ? scope.except(:order) : scope
    @date_range = date_range
    @timezone = timezone.presence || Time.zone&.tzinfo&.name || 'UTC'
  end

  def call
    scoped_events = scoped_events_for_window
    return empty_payload if scoped_events.none?

    range = effective_range(scoped_events)
    bucket = bucket_for(range)
    total_series = grouped_scope(scoped_events, bucket:, range:, default_value: 0).count

    {
      bucket: bucket,
      timezone: @timezone,
      range_started_at: range.begin,
      range_ended_at: range.end,
      points: build_points(scoped_events, total_series, bucket:, range:)
    }
  end

  private

  def scoped_events_for_window
    return @scope.for_date_range(normalized_date_range) if normalized_date_range.present?

    latest_event_at = @scope.maximum(:created_at)
    return @scope.none unless latest_event_at

    earliest_event_at = @scope.minimum(:created_at)
    window_end = latest_event_at.to_time
    window_start = [window_end - DEFAULT_WINDOW, earliest_event_at.to_time].max

    @scope.for_date_range(window_start..window_end)
  end

  def normalized_date_range
    return @normalized_date_range if defined?(@normalized_date_range)
    return @normalized_date_range = nil if @date_range.blank?

    range_start = @date_range.begin.to_time
    range_end = @date_range.exclude_end? ? (@date_range.end.to_time - 1.second) : @date_range.end.to_time
    @normalized_date_range = range_start..range_end
  end

  def effective_range(scoped_events)
    normalized_date_range || begin
      latest_event_at = scoped_events.maximum(:created_at).to_time
      earliest_event_at = scoped_events.minimum(:created_at).to_time
      window_start = [latest_event_at - DEFAULT_WINDOW, earliest_event_at].max

      window_start..latest_event_at
    end
  end

  def bucket_for(range)
    duration = range.end - range.begin
    return 'hour' if duration <= HOURLY_THRESHOLD
    return 'day' if duration <= DAILY_THRESHOLD

    'week'
  end

  def grouped_scope(scope, bucket:, range:, default_value: nil)
    scope.group_by_period(
      bucket,
      :created_at,
      range: range,
      permit: PERMITTED_BUCKETS,
      time_zone: @timezone,
      default_value: default_value
    )
  end

  def build_points(scoped_events, total_series, bucket:, range:)
    request_series = grouped_scope(scoped_events.chat_completions, bucket:, range:, default_value: 0).count
    error_series = grouped_scope(scoped_events.error_events, bucket:, range:, default_value: 0).count
    cost_series = grouped_scope(scoped_events, bucket:, range:, default_value: 0).sum(:estimated_cost)
    latency_series = grouped_scope(
      scoped_events.chat_completions.where.not(duration_ms: nil),
      bucket:,
      range:
    ).average(:duration_ms)

    total_series.keys.map do |timestamp|
      {
        timestamp: timestamp.in_time_zone(@timezone).to_i,
        total_events: total_series[timestamp].to_i,
        request_count: request_series[timestamp].to_i,
        error_count: error_series[timestamp].to_i,
        estimated_cost: cost_series[timestamp].to_f.round(8),
        avg_duration_ms: latency_series[timestamp]&.to_f&.round(2)
      }
    end
  end

  def empty_payload
    {
      bucket: 'day',
      timezone: @timezone,
      range_started_at: nil,
      range_ended_at: nil,
      points: []
    }
  end
end
