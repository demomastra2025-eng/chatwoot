class Integrations::Medelement::Configuration # rubocop:disable Metrics/ClassLength
  INTEGRATOR_KEY_ENV = 'MEDELEMENT_INTEGRATOR_KEY'.freeze
  DEFAULT_DAYS_BACK = 3
  DEFAULT_DAYS_FORWARD = 89
  # MedElement allows five requests per second for each request type of an account.
  DEFAULT_THROTTLE_MS = Integrations::Medelement::RequestRateLimiter::DEFAULT_INTERVAL_MS
  DEFAULT_GLOBAL_THROTTLE_MS = 125
  DEFAULT_REQUEST_BUDGET_PER_MINUTE = 30
  DEFAULT_LIVE_RESERVE_PER_MINUTE = 10
  DEFAULT_RATE_ALERT_THRESHOLD_PER_HOUR = 3
  DEFAULT_SYNC_INTERVAL_HOURS = 0.25
  CATALOG_SYNC_INTERVAL_HOURS = 6
  RECEPTIONS_SYNC_INTERVAL_MINUTES = 2
  DELTA_INTERVAL_SECONDS = 60
  DELTA_INTERVAL_OPTIONS = [10, 30, 60, 120].freeze
  WORKING_HOURS_RANGE = (7..20)
  NIGHT_DELTA_INTERVAL_ENV = 'MEDELEMENT_NIGHT_DELTA_INTERVAL_MINUTES'.freeze
  DEFAULT_NIGHT_DELTA_INTERVAL_MINUTES = 15
  NIGHT_DELTA_INTERVAL_OPTIONS = [5, 10, 15, 30].freeze
  ADAPTIVE_FULL_SWEEP_STEPS_MINUTES = [2, 4, 8, 15, 30, 60].freeze
  FULL_SWEEP_INTERVAL_OPTIONS = [2, 4, 8, 15, 30, 60, 1440].freeze
  FULL_SWEEP_BACKOFF_CURSOR_NAME = 'receptions_full_sweep_backoff'.freeze
  DEFAULT_RECEPTION_DETAIL_REFRESH_MINUTES = 360
  DEFAULT_RECEPTION_DETAIL_BUDGET = 50
  DEFAULT_SYNC_TIME_OF_DAY = '06:15'.freeze
  SUPPORTED_SYNC_INTERVAL_HOURS = [0.25, 0.5, 1, 2, 4, 6, 12, 24].freeze
  TIME_OF_DAY_FORMAT = /\A([01]\d|2[0-3]):[0-5]\d\z/
  DEFAULT_REQUIRED_PATIENT_FIELDS = {
    first_name: true,
    phone: true,
    last_name: false,
    iin: false,
    middle_name: false,
    birth_date: false
  }.freeze

  def self.for_account(account)
    return unless account

    hook = account.hooks.where(app_id: 'medelement', status: :enabled).order(:id).last ||
           account.hooks.where(app_id: 'medelement').order(:id).last
    new(hook: hook) if hook
  end

  def self.required_patient_fields_for(account)
    for_account(account)&.required_patient_fields || DEFAULT_REQUIRED_PATIENT_FIELDS.dup
  end

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
    [integer_setting('receptions_days_forward', DEFAULT_DAYS_FORWARD), DEFAULT_DAYS_FORWARD].max
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

  def incremental_receptions_enabled?
    boolean_setting('incremental_receptions_enabled', true)
  end

  # The daily probe switches incremental_receptions_enabled on and off by itself. Setting this to false pins the
  # current value of that flag for one clinic.
  def delta_probe_enabled?
    boolean_setting('delta_probe_enabled', true)
  end

  def incremental_receptions_interval_seconds
    supported_integer_setting('incremental_receptions_interval_seconds', DELTA_INTERVAL_SECONDS, DELTA_INTERVAL_OPTIONS)
  end

  def receptions_full_sweep_interval_minutes
    configured = supported_integer_setting('receptions_full_sweep_interval_minutes', RECEPTIONS_SYNC_INTERVAL_MINUTES,
                                           FULL_SWEEP_INTERVAL_OPTIONS)
    return configured if configured > RECEPTIONS_SYNC_INTERVAL_MINUTES || !incremental_receptions_enabled?

    adaptive_full_sweep_interval_minutes || configured
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

  def night_delta_throttle_enabled?
    boolean_setting('night_delta_throttle_enabled', true)
  end

  def night_delta_interval_minutes
    raw = hook.settings['night_delta_interval_minutes'].presence || ENV.fetch(NIGHT_DELTA_INTERVAL_ENV, nil).presence
    return DEFAULT_NIGHT_DELTA_INTERVAL_MINUTES if raw.blank?

    parsed = raw.to_i
    NIGHT_DELTA_INTERVAL_OPTIONS.include?(parsed) ? parsed : DEFAULT_NIGHT_DELTA_INTERVAL_MINUTES
  end

  def off_hours?(at = Time.current)
    return false unless night_delta_throttle_enabled?

    local_hour = at.in_time_zone(time_zone).hour
    !WORKING_HOURS_RANGE.cover?(local_hour)
  end

  def effective_incremental_receptions_interval_seconds(at = Time.current)
    base = incremental_receptions_interval_seconds
    return base unless off_hours?(at)

    [base, night_delta_interval_minutes * 60].max
  end

  def sync_cron_expression
    offset = default_sync_anchor? ? hook_stagger_offset(60, multiplier: 11) : 0
    cron_expression(interval_hours: sync_interval_hours, minute_offset: offset)
  end

  def catalog_sync_cron_expression
    # Spread default catalog syncs across the full 6-hour (360-minute) window via coprime step 77.
    extra_offset = default_sync_anchor? ? hook_stagger_offset(360, multiplier: 77) : 0
    cron_expression(interval_hours: CATALOG_SYNC_INTERVAL_HOURS, minute_offset: 5 + extra_offset)
  end

  def receptions_sync_cron_expression
    interval = receptions_full_sweep_interval_minutes
    return daily_receptions_sync_cron_expression if interval >= 1440
    return "#{realtime_stagger_offset(60)} */#{interval / 60} * * * #{time_zone}" if interval >= 60

    sub_hour_step_cron_expression(interval, hours: '*')
  end

  def receptions_delta_cron_expression
    hours = night_delta_throttle_enabled? ? '7-20' : '*'
    interval = incremental_receptions_interval_seconds
    return sub_hour_step_cron_expression(interval / 60, hours: hours) if interval >= 120

    "* #{hours} * * * #{time_zone}"
  end

  def receptions_delta_night_cron_expression
    return unless night_delta_throttle_enabled?

    step = night_delta_interval_minutes
    offset = hook_stagger_offset(step, multiplier: 19)
    minutes = cron_minutes(offset, step / 60.0).join(',')
    "#{minutes} 0-6,21-23 * * * #{time_zone}"
  end

  def contacts_sync_cron_expression
    minute = (hook.id.to_i * 13) % 60
    "#{minute} * * * * #{time_zone}"
  end

  def reception_detail_refresh_interval
    integer_setting('reception_detail_refresh_minutes', DEFAULT_RECEPTION_DETAIL_REFRESH_MINUTES).clamp(15, 24 * 60).minutes
  end

  def reception_detail_budget
    integer_setting('reception_detail_budget', DEFAULT_RECEPTION_DETAIL_BUDGET).clamp(1, 500)
  end

  # The pause between two requests of one type is never shorter than the provider allows (five per second), whatever a
  # hook saved: a smaller value would let the clinic go over the provider's limit.
  def throttle_ms
    [integer_setting('throttle_ms', DEFAULT_THROTTLE_MS), DEFAULT_THROTTLE_MS].max
  end

  def global_throttle_ms
    [integer_setting('global_throttle_ms', DEFAULT_GLOBAL_THROTTLE_MS), DEFAULT_GLOBAL_THROTTLE_MS].max
  end

  def request_budget_per_minute
    integer_setting('request_budget_per_minute', DEFAULT_REQUEST_BUDGET_PER_MINUTE).clamp(2, 300)
  end

  def live_reserve_per_minute
    integer_setting('live_reserve_per_minute', DEFAULT_LIVE_RESERVE_PER_MINUTE).clamp(1, request_budget_per_minute - 1)
  end

  def rate_alert_threshold_per_hour
    integer_setting('rate_alert_threshold_per_hour', DEFAULT_RATE_ALERT_THRESHOLD_PER_HOUR).clamp(1, 1000)
  end

  def account_id = hook.account_id
  def hook_id = hook.id

  def time_zone
    zone = ActiveSupport::TimeZone[setting('timezone', Scheduling::Constants::DEFAULT_TIMEZONE)]
    zone&.name || Scheduling::Constants::DEFAULT_TIMEZONE
  end

  def write_enabled?
    boolean_setting('write_enabled', false)
  end

  # Off by default: until the owner has reviewed a dry run, the nightly stale status reconciliation only reads MedElement and
  # logs what it would change. A run started with an explicit dry_run: false (the rake task) applies whatever this says.
  def stale_status_apply_enabled?
    boolean_setting('stale_status_apply_enabled', false)
  end

  # Off by default: a OneLink cancellation keeps the MedElement reception (owner decision 01.10.2026).
  def remove_reception_on_cancel?
    boolean_setting('remove_reception_on_cancel', false)
  end

  def require_patient_last_name?
    boolean_setting('require_patient_last_name', false)
  end

  def require_patient_iin?
    boolean_setting('require_patient_iin', false)
  end

  def require_patient_middle_name?
    boolean_setting('require_patient_middle_name', false)
  end

  def require_patient_birth_date?
    boolean_setting('require_patient_birth_date', false)
  end

  def required_patient_fields
    {
      first_name: true,
      phone: true,
      last_name: require_patient_last_name?,
      iin: require_patient_iin?,
      middle_name: require_patient_middle_name?,
      birth_date: require_patient_birth_date?
    }
  end

  private

  attr_reader :hook

  def default_sync_anchor?
    sync_time_of_day == DEFAULT_SYNC_TIME_OF_DAY && hook.id.to_i.positive?
  end

  def hook_stagger_offset(modulus, multiplier:, shift: 0)
    id = hook.id.to_i
    return 0 unless id.positive?

    ((id * multiplier) + shift) % modulus
  end

  # (id * 7 + 3) mod 60 never collides with contacts (id * 13) mod 60 because 6*id is even and 3 is odd.
  def realtime_stagger_offset(modulus)
    hook_stagger_offset(modulus, multiplier: 7, shift: 3)
  end

  def daily_receptions_sync_cron_expression
    minute = realtime_stagger_offset(60)
    hour = hook_stagger_offset(24, multiplier: 5)
    "#{minute} #{hour} * * * #{time_zone}"
  end

  def sub_hour_step_cron_expression(interval_minutes, hours:)
    return "* #{hours} * * * #{time_zone}" if interval_minutes <= 1

    offset = realtime_stagger_offset(interval_minutes)
    minute_expr = if [15, 30].include?(interval_minutes)
                    cron_minutes(offset, interval_minutes / 60.0).join(',')
                  elsif offset.zero?
                    "*/#{interval_minutes}"
                  else
                    "#{offset}-59/#{interval_minutes}"
                  end
    "#{minute_expr} #{hours} * * * #{time_zone}"
  end

  def adaptive_full_sweep_interval_minutes
    return unless hook.id

    cursor = Integrations::Medelement::SyncCursor.find_by(hook_id: hook.id, name: FULL_SWEEP_BACKOFF_CURSOR_NAME)
    minutes = cursor&.current_interval_seconds.to_i / 60
    minutes if ADAPTIVE_FULL_SWEEP_STEPS_MINUTES.include?(minutes)
  end

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

  def supported_integer_setting(key, default, options)
    value = integer_setting(key, default)
    options.include?(value) ? value : default
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
