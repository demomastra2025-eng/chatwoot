class Integrations::Medelement::ProviderSchedulePresenter
  HORIZON_DAYS = Integrations::Medelement::SchedulesSyncService::SCHEDULE_HORIZON_DAYS

  def initialize(account:, resources:, now: Time.current)
    @account = account
    @resources = Array(resources)
    @now = now
  end

  def payloads
    return {} if linked_resources.empty?

    hook = Integrations::Hook.find_by(account_id: account.id, app_id: 'medelement')
    return linked_resources.index_with { empty_payload } unless hook

    days = schedule_days(hook)
    rules = work_rules
    linked_resources.index_with do |resource|
      resource_payload(days.fetch(resource.id, []), rules.fetch(resource.id, []))
    end
  end

  private

  attr_reader :account, :now, :resources

  def linked_resources
    @linked_resources ||= resources.select { |resource| resource.custom_attributes['medelement_specialist_code'].present? }
  end

  def schedule_days(hook)
    @today = now.in_time_zone(Integrations::Medelement::Configuration.new(hook: hook).time_zone).to_date
    Integrations::Medelement::ScheduleDay.where(
      account_id: account.id, hook_id: hook.id, resource_id: linked_resources.map(&:id),
      date: @today...(@today + HORIZON_DAYS)
    ).order(:date).group_by(&:resource_id)
  end

  def work_rules
    Scheduling::WorkRule.active.where(account_id: account.id, resource_id: linked_resources.map(&:id)).group_by(&:resource_id)
  end

  def resource_payload(resource_days, rules)
    by_date = resource_days.index_by(&:date)
    {
      checked_at: resource_days.filter_map(&:source_checked_at).max&.iso8601,
      horizon_days: HORIZON_DAYS,
      days: Array.new(HORIZON_DAYS) { |offset| day_payload(by_date[@today + offset], @today + offset) },
      differs_from_template: resource_days.any? { |day| differs?(day, rules) }
    }
  end

  def empty_payload
    { checked_at: nil, horizon_days: HORIZON_DAYS, days: [], differs_from_template: false }
  end

  def day_payload(day, date)
    {
      date: date.iso8601,
      windows: Array(day&.windows).map { |window| { start: time(window['start_minute']), end: time(window['end_minute']) } },
      status: day&.status || 'unverified'
    }
  end

  def differs?(day, rules)
    return false unless day.status.in?(%w[confirmed empty_confirmed])

    provider = day.windows.map { |window| [window['start_minute'], window['end_minute']] }.sort
    local = rules.select { |rule| rule.weekday == day.date.wday }.map { |rule| [rule.start_minute, rule.end_minute] }.sort
    provider != local
  end

  def time(minute)
    minute.divmod(60).map { |part| part.to_s.rjust(2, '0') }.join(':')
  end
end
