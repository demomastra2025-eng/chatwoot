class Integrations::Medelement::ScheduleChangeTracker
  RETENTION = 72.hours.to_i

  def initialize(hook:, pool: nil)
    @hook = hook
    @pool = pool || $alfred # rubocop:disable Style/GlobalVars
  end

  def mark_reception!(detail)
    resource = resource_for(detail)
    date = reception_date(detail)
    return unless resource && date

    pool.with do |redis|
      redis.hset(key(resource.id), date.iso8601, Time.current.iso8601)
      redis.expire(key(resource.id), RETENTION)
    end
  rescue ArgumentError, TypeError
    nil
  rescue Redis::BaseConnectionError, ConnectionPool::TimeoutError => e
    Rails.logger.warn("[MEDELEMENT::SCHEDULE_CHANGES] mark failed: #{e.class.name}")
    nil
  end

  def changes_for(resource_id)
    pool.with { |redis| redis.hgetall(key(resource_id)) }
  rescue Redis::BaseConnectionError, ConnectionPool::TimeoutError => e
    Rails.logger.warn("[MEDELEMENT::SCHEDULE_CHANGES] read failed: #{e.class.name}")
    {}
  end

  private

  attr_reader :hook, :pool

  def key(resource_id) = "medelement:schedule_changes:#{hook.id}:#{resource_id}"

  def resource_for(detail)
    code = detail['SPECIALIST_CODE'].presence || detail['specialistCode'].presence
    return if code.blank?

    hook.account.scheduling_resources.find_by("custom_attributes ->> 'medelement_specialist_code' = ?", code.to_s)
  end

  def reception_date(detail)
    zone = ActiveSupport::TimeZone[Integrations::Medelement::Configuration.new(hook: hook).time_zone]
    starts_at = zone.parse(detail['STARTTIME'].to_s)
    return unless starts_at

    starts_at.to_date
  end
end
