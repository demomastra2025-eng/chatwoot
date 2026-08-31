class Integrations::Medelement::Configuration
  INTEGRATOR_KEY_ENV = 'MEDELEMENT_INTEGRATOR_KEY'.freeze
  DEFAULT_DAYS_BACK = 3
  DEFAULT_DAYS_FORWARD = 70
  DEFAULT_THROTTLE_MS = 275
  DEFAULT_SYNC_INTERVAL_HOURS = 0.25
  CATALOG_SYNC_INTERVAL_HOURS = 6
  RECEPTIONS_SYNC_INTERVAL_MINUTES = 2
  DEFAULT_RECEPTION_DETAIL_REFRESH_MINUTES = 360
  DEFAULT_RECEPTION_DETAIL_BUDGET = 50
  DEFAULT_SYNC_TIME_OF_DAY = '06:15'.freeze
  SUPPORTED_SYNC_INTERVAL_HOURS = [0.25, 0.5, 1, 2, 4, 6, 12, 24].freeze
  TIME_OF_DAY_FORMAT = /\A([01]\d|2[0-3]):[0-5]\d\z/

  def initialize(hook:)
    @hook = hook
  end

  def company_login
    credentials['company_login'].to_s
  end

  def integrator_key
    ENV[INTEGRATOR_KEY_ENV].presence || credentials['integrator_key'].to_s
  end

  def organization_id
    setting('organization_id')
  end

  def password
    credentials['password'].to_s
  end

  def receptions_days_back
    integer_setting('receptions_days_back', DEFAULT_DAYS_BACK)
  end

  def receptions_days_forward
    integer_setting('receptions_days_forward', DEFAULT_DAYS_FORWARD)
  end

  def sync_patients?
    boolean_setting('sync_patients', true)
  end

  def sync_interval_hours
    value = numeric_setting('sync_interval_hours', DEFAULT_SYNC_INTERVAL_HOURS)
    SUPPORTED_SYNC_INTERVAL_HOURS.find { |supported_value| supported_value == value } ||
      DEFAULT_SYNC_INTERVAL_HOURS
  end

  def sync_receptions?
    boolean_setting('sync_receptions', true)
  end

  def sync_services?
    boolean_setting('sync_services', true)
  end

  def sync_specialists?
    boolean_setting('sync_specialists', true)
  end

  def sync_time_of_day
    value = setting('sync_time_of_day', DEFAULT_SYNC_TIME_OF_DAY).to_s
    return value if value.match?(TIME_OF_DAY_FORMAT)

    DEFAULT_SYNC_TIME_OF_DAY
  end

  def sync_cron_expression
    cron_expression(interval_hours: sync_interval_hours)
  end

  def catalog_sync_cron_expression
    cron_expression(interval_hours: CATALOG_SYNC_INTERVAL_HOURS, minute_offset: 5)
  end

  def receptions_sync_cron_expression
    "*/#{RECEPTIONS_SYNC_INTERVAL_MINUTES} * * * * #{time_zone}"
  end

  def contacts_sync_cron_expression
    minute = (hook.id * 13) % 60
    "#{minute} * * * * #{time_zone}"
  end

  def reception_detail_refresh_interval
    integer_setting('reception_detail_refresh_minutes', DEFAULT_RECEPTION_DETAIL_REFRESH_MINUTES).clamp(15, 24 * 60).minutes
  end

  def reception_detail_budget
    integer_setting('reception_detail_budget', DEFAULT_RECEPTION_DETAIL_BUDGET).clamp(1, 500)
  end

  def throttle_ms
    integer_setting('throttle_ms', DEFAULT_THROTTLE_MS)
  end

  def time_zone
    zone = ActiveSupport::TimeZone[setting('timezone', Scheduling::Constants::DEFAULT_TIMEZONE)]
    zone&.name || Scheduling::Constants::DEFAULT_TIMEZONE
  end

  def write_enabled?
    boolean_setting('write_enabled', false)
  end

  private

  attr_reader :hook

  def cron_expression(interval_hours:, minute_offset: 0)
    anchor_hour, anchor_minute = sync_time_of_day.split(':').map(&:to_i)
    anchor_total_minutes = ((anchor_hour * 60) + anchor_minute + minute_offset) % (24 * 60)
    anchor_hour, anchor_minute = anchor_total_minutes.divmod(60)

    return "#{cron_minutes(anchor_minute, interval_hours).join(',')} * * * * #{time_zone}" if interval_hours < 1

    "#{anchor_minute} #{cron_hours(anchor_hour, interval_hours).join(',')} * * * #{time_zone}"
  end

  def cron_hours(anchor_hour, interval_hours)
    return [anchor_hour] if interval_hours == 24

    hours = []
    hour = anchor_hour

    loop do
      break if hours.include?(hour)

      hours << hour
      hour = (hour + interval_hours) % 24
    end

    hours.sort
  end

  def cron_minutes(anchor_minute, interval_hours)
    interval_minutes = (interval_hours * 60).to_i
    minutes = []
    minute = anchor_minute

    loop do
      break if minutes.include?(minute)

      minutes << minute
      minute = (minute + interval_minutes) % 60
    end

    minutes.sort
  end

  def boolean_setting(key, default)
    return default unless hook.settings.key?(key)

    ActiveModel::Type::Boolean.new.cast(hook.settings[key])
  end

  def credentials
    hook.secret_settings
  end

  def integer_setting(key, default)
    value = hook.settings[key]
    return default if value.blank?

    value.to_i
  end

  def numeric_setting(key, default)
    value = hook.settings[key]
    return default if value.blank?

    Float(value, exception: false) || default
  end

  def setting(key, default = nil)
    hook.settings[key].presence || default
  end
end
