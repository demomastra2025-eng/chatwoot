class Crm::Reports::StageDurationSqlFragments
  PERCENTILE_SQL_VALUES = { 0.5 => '0.5', 0.75 => '0.75' }.freeze
  RELIABILITY_FILTER_VALUES = %w[exact estimated].freeze
  HISTOGRAM_BUCKETS = [
    { key: 'under_1_hour', from: 0, to: 1.hour.to_i },
    { key: '1_to_4_hours', from: 1.hour.to_i, to: 4.hours.to_i },
    { key: '4_to_24_hours', from: 4.hours.to_i, to: 1.day.to_i },
    { key: '1_to_3_days', from: 1.day.to_i, to: 3.days.to_i },
    { key: '3_to_7_days', from: 3.days.to_i, to: 7.days.to_i },
    { key: '7_to_30_days', from: 7.days.to_i, to: 30.days.to_i },
    { key: '30_days_or_more', from: 30.days.to_i, to: nil }
  ].freeze

  def initialize(connection:)
    @connection = connection
  end

  def percentile_sql(percentile, reliability: nil)
    percentile_sql = PERCENTILE_SQL_VALUES.fetch(Float(percentile))
    aggregate_sql = "PERCENTILE_CONT(#{percentile_sql}) WITHIN GROUP (ORDER BY duration_seconds)"
    return Arel.sql(aggregate_sql) if reliability.blank?

    validate_reliability!(reliability)
    Arel.sql("#{aggregate_sql} FILTER (WHERE reliability = #{connection.quote(reliability)})")
  end

  def histogram_sql
    HISTOGRAM_BUCKETS.map do |bucket|
      predicate = ["duration_seconds >= #{connection.quote(Integer(bucket.fetch(:from)))}"]
      predicate << "duration_seconds < #{connection.quote(Integer(bucket.fetch(:to)))}" if bucket[:to]
      Arel.sql("COUNT(*) FILTER (WHERE #{predicate.join(' AND ')})")
    end
  end

  def histogram_payload(counts)
    HISTOGRAM_BUCKETS.zip(counts).map do |bucket, count|
      bucket.merge(count: count.to_i)
    end
  end

  private

  attr_reader :connection

  def validate_reliability!(reliability)
    raise ArgumentError, 'Unsupported reliability filter' unless reliability.in?(RELIABILITY_FILTER_VALUES)
  end
end
