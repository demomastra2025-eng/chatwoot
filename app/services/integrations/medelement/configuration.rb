class Integrations::Medelement::Configuration
  INTEGRATOR_KEY_ENV = 'MEDELEMENT_INTEGRATOR_KEY'.freeze
  DEFAULT_DAYS_BACK = 3
  DEFAULT_DAYS_FORWARD = 70
  DEFAULT_THROTTLE_MS = 275
  DEFAULT_SYNC_INTERVAL_HOURS = 24
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

  def sync_specialists?
    boolean_setting('sync_specialists', true)
  end

  def sync_time_of_day
    value = setting('sync_time_of_day', DEFAULT_SYNC_TIME_OF_DAY).to_s
    return value if value.match?(TIME_OF_DAY_FORMAT)

    DEFAULT_SYNC_TIME_OF_DAY
  end

  def sync_cron_expression
    anchor_hour, anchor_minute = sync_time_of_day.split(':').map(&:to_i)

    return "#{cron_minutes(anchor_minute).join(',')} * * * * #{time_zone}" if sync_interval_hours < 1

    "#{anchor_minute} #{cron_hours(anchor_hour).join(',')} * * * #{time_zone}"
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

  def cron_hours(anchor_hour)
    return [anchor_hour] if sync_interval_hours == 24

    hours = []
    hour = anchor_hour

    loop do
      break if hours.include?(hour)

      hours << hour
      hour = (hour + sync_interval_hours) % 24
    end

    hours.sort
  end

  def cron_minutes(anchor_minute)
    interval_minutes = (sync_interval_hours * 60).to_i
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
