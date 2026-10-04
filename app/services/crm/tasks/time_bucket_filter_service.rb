class Crm::Tasks::TimeBucketFilterService
  BUCKET_METHODS = {
    'overdue' => :overdue_scope,
    'today' => :today_scope,
    'tomorrow' => :tomorrow_scope,
    'nextWeek' => :next_week_scope,
    'thisMonth' => :this_month_scope,
    'future' => :future_scope
  }.freeze
  TIME_BUCKETS = (BUCKET_METHODS.keys + %w[unscheduled]).freeze

  def initialize(scope:, account:, params:)
    @scope = scope
    @account = account
    @params = params
  end

  def perform
    bucket = params[:time_bucket].to_s
    return scope if bucket.blank?
    return scope.none unless TIME_BUCKETS.include?(bucket)
    return scope.where(due_at: nil, due_on: nil) if bucket == 'unscheduled'

    send(BUCKET_METHODS.fetch(bucket))
  end

  private

  attr_reader :scope, :account, :params

  def overdue_scope
    boundaries = time_bucket_boundaries
    scope.where(
      'crm_tasks.due_at < :now OR crm_tasks.due_on < :today',
      now: boundaries[:now],
      today: boundaries[:today]
    )
  end

  def today_scope
    boundaries = time_bucket_boundaries
    due_bucket_scope(scope, boundaries[:now], boundaries[:tomorrow], boundaries[:today], boundaries[:tomorrow_date])
  end

  def tomorrow_scope
    boundaries = time_bucket_boundaries
    due_bucket_scope(
      scope,
      boundaries[:tomorrow],
      boundaries[:day_after_tomorrow],
      boundaries[:tomorrow_date],
      boundaries[:day_after_tomorrow_date]
    )
  end

  def next_week_scope
    boundaries = time_bucket_boundaries
    due_bucket_scope(
      scope,
      boundaries[:day_after_tomorrow],
      boundaries[:next_week],
      boundaries[:day_after_tomorrow_date],
      boundaries[:next_week_date]
    )
  end

  def this_month_scope
    boundaries = time_bucket_boundaries
    due_bucket_scope(
      scope,
      boundaries[:next_week],
      boundaries[:next_month],
      boundaries[:next_week_date],
      boundaries[:next_month_date]
    )
  end

  def future_scope
    boundaries = time_bucket_boundaries
    scope.where(
      'crm_tasks.due_at >= :next_month OR crm_tasks.due_on >= :next_month_date',
      next_month: boundaries[:next_month],
      next_month_date: boundaries[:next_month_date]
    )
  end

  def due_bucket_scope(relation, from, to, from_date, to_date)
    relation.where(
      <<~SQL.squish,
        (crm_tasks.due_at >= :from AND crm_tasks.due_at < :to) OR
        (crm_tasks.due_on >= :from_date AND crm_tasks.due_on < :to_date)
      SQL
      from: from,
      to: to,
      from_date: from_date,
      to_date: to_date
    )
  end

  def time_bucket_boundaries
    timezone = ::Crm::WorkspaceTimezone.resolve(account)
    now = (parse_datetime(:as_of) || Time.current).in_time_zone(timezone)
    today = now.to_date
    tomorrow_date = today + 1.day
    day_after_tomorrow_date = today + 2.days
    next_week_date = today + 8.days
    next_month_date = today.advance(months: 1)

    {
      now: now,
      today: today,
      tomorrow: tomorrow_date.in_time_zone(timezone),
      tomorrow_date: tomorrow_date,
      day_after_tomorrow: day_after_tomorrow_date.in_time_zone(timezone),
      day_after_tomorrow_date: day_after_tomorrow_date,
      next_week: next_week_date.in_time_zone(timezone),
      next_week_date: next_week_date,
      next_month: next_month_date.in_time_zone(timezone),
      next_month_date: next_month_date
    }
  end

  def parse_datetime(field_name)
    value = params[field_name]
    return if value.blank?

    Time.zone.parse(value.to_s) || raise(ArgumentError, "#{field_name} must be a valid datetime")
  end
end
