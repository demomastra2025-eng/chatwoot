class Scheduling::ResourceScheduleService
  MAX_RANGE_DAYS = Scheduling::RangeValidator::MAX_RANGE_DAYS

  def initialize(resource:, from:, to:, include_breaks: true, include_holidays: true, include_time_offs: true, snapshots: nil, resource_payload: nil)
    @resource = resource
    @account = resource.account
    @from = from
    @to = to
    @include_breaks = ActiveModel::Type::Boolean.new.cast(include_breaks)
    @include_holidays = ActiveModel::Type::Boolean.new.cast(include_holidays)
    @include_time_offs = ActiveModel::Type::Boolean.new.cast(include_time_offs)
    @resource_payload = resource_payload
    return unless snapshots

    @snapshots = snapshots
    @holidays = snapshots.fetch(:holidays)
    @workday_overrides = snapshots.fetch(:workday_overrides)
    @time_offs = snapshots.fetch(:time_offs)
  end

  def perform
    validate_range!

    {
      resource: @resource_payload || Scheduling::PayloadBuilder.resource(@resource),
      timezone: time_zone.tzinfo.name,
      range: {
        from: @from.iso8601,
        to: @to.iso8601
      },
      days: local_dates.map { |date| day_payload(date) }
    }
  end

  private

  def day_payload(date)
    return provider_day_payload(date) if provider_hours?

    override = workday_overrides.find { |item| item.date == date }
    matching_holidays = holidays_for_date(date)
    workspace_closed = @resource.inherit_working_hours_from_account? && @account.workspace_day_off?(date)
    holiday_blocked = workspace_closed || holiday_blocks_date?(matching_holidays)
    working_intervals = working_intervals_for_date(date, override, holiday_blocked, workspace_closed)
    breaks = @include_breaks && !workspace_closed ? breaks_for_date(date, override) : []
    time_offs = @include_time_offs ? time_offs_for_date(date) : []

    {
      date: date.iso8601,
      working: working_intervals.any?,
      source: schedule_source(override, holiday_blocked, working_intervals, workspace_closed),
      windows: serialize_intervals(working_intervals),
      breaks: serialize_intervals(breaks, include_title: true),
      holidays: serialize_holidays(matching_holidays),
      time_offs: serialize_time_offs(time_offs)
    }
  end

  def serialize_intervals(intervals, include_title: false)
    Array(intervals).filter_map do |interval|
      payload = Scheduling::IntervalMath.clip(interval.values_at(:start_at, :end_at), from: @from, to: @to)
      next if payload.nil?

      result = {
        start_at: serialize_time(payload[0]),
        end_at: serialize_time(payload[1])
      }
      result[:title] = interval[:title] if include_title && interval[:title].present?
      result
    end
  end

  def serialize_holidays(holidays)
    return [] unless @include_holidays

    Array(holidays).map do |holiday|
      {
        title: holiday.title,
        working_day_override: holiday.working_day_override,
        recurring_yearly: holiday.recurring_yearly
      }
    end
  end

  def serialize_time_offs(time_offs)
    return [] unless @include_time_offs

    Array(time_offs).filter_map do |time_off|
      interval = Scheduling::IntervalMath.clip([time_off.starts_at, time_off.ends_at], from: @from, to: @to)
      next if interval.nil?

      {
        start_at: serialize_time(interval[0]),
        end_at: serialize_time(interval[1]),
        title: time_off.title,
        kind: time_off.kind
      }
    end
  end

  def schedule_source(override, holiday_blocked, working_intervals, workspace_closed)
    return 'holiday' if workspace_closed
    return 'override' if override.present?
    return 'holiday' if holiday_blocked
    return 'weekly_rules' if working_intervals.any?

    'no_rules'
  end

  def validate_range!
    Scheduling::RangeValidator.validate!(from: @from, to: @to, max_days: MAX_RANGE_DAYS)
  end

  def serialize_time(value)
    value.in_time_zone(time_zone).iso8601
  end

  def holidays_for_date(date)
    @holidays ||= @account.scheduling_holidays.ordered.to_a
    @holidays.select do |holiday|
      if holiday.recurring_yearly?
        holiday.date.month == date.month && holiday.date.day == date.day
      else
        holiday.date == date
      end
    end
  end

  def holiday_blocks_date?(matching_holidays)
    matching_holidays.present? && matching_holidays.none?(&:working_day_override?)
  end

  def workday_overrides
    @workday_overrides ||= @resource.workday_overrides.where(date: local_dates).ordered.to_a
  end

  def working_intervals_for_date(date, override, holiday_blocked, workspace_closed)
    return [] if workspace_closed
    return [interval_hash(local_time(date, override.start_minute), local_time(date, override.end_minute))] if override.present?
    return [] if holiday_blocked

    @resource.work_rules.active.select { |rule| rule.weekday == date.wday }.map do |rule|
      interval_hash(local_time(date, rule.start_minute), local_time(date, rule.end_minute))
    end
  end

  def breaks_for_date(date, override)
    if override.present?
      return [] if override.break_start_minute.blank? || override.break_end_minute.blank?

      return [interval_hash(local_time(date, override.break_start_minute), local_time(date, override.break_end_minute), title: 'Break')]
    end

    @resource.break_rules.active.select { |rule| rule.weekday == date.wday }.map do |rule|
      interval_hash(local_time(date, rule.start_minute), local_time(date, rule.end_minute), title: rule.title)
    end
  end

  def time_offs_for_date(date)
    day_start = time_zone.local(date.year, date.month, date.day, 0, 0, 0)
    day_end = day_start + 1.day

    @time_offs ||= @account.scheduling_time_offs.where(resource_id: [nil, @resource.id]).ordered.to_a
    @time_offs.select { |time_off| time_off.ends_at > day_start && time_off.starts_at < day_end }
  end

  def local_dates
    start_date = @from.in_time_zone(time_zone).to_date
    end_date = (@to - 1.second).in_time_zone(time_zone).to_date
    return [] if end_date < start_date

    (start_date..end_date).to_a
  end

  def interval_hash(start_at, end_at, title: nil)
    { start_at: start_at, end_at: end_at, title: title }
  end

  def local_time(date, minute_of_day)
    time_zone.local(date.year, date.month, date.day, minute_of_day / 60, minute_of_day % 60, 0)
  end

  def provider_hours?
    return @provider_hours if defined?(@provider_hours)

    @provider_hours = @snapshots.nil? &&
                      @resource.respond_to?(:custom_attributes) &&
                      Scheduling::ResourceHoursPolicy.new(resource: @resource).provider_hours?
  end

  def provider_day_payload(date)
    day = provider_schedule_days[date]
    working_intervals = if day&.status == 'confirmed'
                          Array(day.windows).filter_map do |window|
                            attrs = window.to_h.with_indifferent_access
                            start_min = attrs[:start_minute].to_i
                            end_min = attrs[:end_minute].to_i
                            next if end_min <= start_min

                            interval_hash(local_time(date, start_min), local_time(date, end_min))
                          end
                        else
                          []
                        end
    serialized_windows = serialize_intervals(working_intervals)
    source = if day&.status.in?(%w[confirmed empty_confirmed])
               'medelement'
             else
               'medelement_unconfirmed'
             end

    {
      date: date.iso8601,
      working: serialized_windows.any?,
      source: source,
      windows: serialized_windows,
      breaks: [],
      holidays: [],
      time_offs: []
    }
  end

  def provider_schedule_days
    @provider_schedule_days ||= Integrations::Medelement::ScheduleDay
                                .where(account_id: @account.id, resource_id: @resource.id, date: local_dates)
                                .index_by(&:date)
  end

  def time_zone
    @time_zone ||= ActiveSupport::TimeZone[@resource.timezone] || Time.zone
  end
end
