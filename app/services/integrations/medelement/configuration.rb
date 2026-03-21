class Integrations::Medelement::Configuration
  DEFAULT_DAYS_BACK = 3
  DEFAULT_DAYS_FORWARD = 70
  DEFAULT_THROTTLE_MS = 275

  def initialize(hook:)
    @hook = hook
  end

  def company_login
    credentials['company_login'].to_s
  end

  def integrator_key
    credentials['integrator_key'].to_s
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

  def sync_receptions?
    boolean_setting('sync_receptions', true)
  end

  def sync_specialists?
    boolean_setting('sync_specialists', true)
  end

  def throttle_ms
    integer_setting('throttle_ms', DEFAULT_THROTTLE_MS)
  end

  def time_zone
    zone = ActiveSupport::TimeZone[setting('timezone', Scheduling::Constants::DEFAULT_TIMEZONE)]
    zone&.name || Scheduling::Constants::DEFAULT_TIMEZONE
  end

  private

  attr_reader :hook

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

  def setting(key, default = nil)
    hook.settings[key].presence || default
  end
end
