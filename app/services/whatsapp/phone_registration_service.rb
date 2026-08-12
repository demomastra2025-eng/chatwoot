# The provider mutation and its durable recovery transitions intentionally stay in one state machine.
# rubocop:disable Metrics/ClassLength
class Whatsapp::PhoneRegistrationService
  CONFIG_KEY = 'phone_registration'.freeze
  VERIFIED_PIN_KEY = 'verification_pin'.freeze
  RATE_LIMIT_WINDOW = 72.hours
  HEALTH_RECONCILIATION_GRACE = 10.minutes
  MAX_REGISTRATION_ATTEMPTS = 10
  PIN_CIPHER = 'aes-256-gcm'.freeze
  PIN_PURPOSE = 'whatsapp_phone_registration_pin:v1'.freeze
  PENDING_PIN_CIPHERTEXT_KEY = 'pending_pin_ciphertext'.freeze
  AMBIGUOUS_STATUSES = %w[registering outcome_unknown].freeze
  BLOCKING_AUTOMATIC_STATUSES = %w[
    registered registering registration_incomplete pin_incorrect phone_verification_required rate_limited
    registration_failed outcome_unknown
  ].freeze
  PROVIDER_ERROR_CODES = {
    133_005 => 'pin_incorrect',
    133_006 => 'phone_verification_required',
    133_016 => 'rate_limited'
  }.freeze

  class Error < StandardError
    attr_reader :error_code, :provider_code, :retry_after_at

    def initialize(error_code:, provider_code: nil, retry_after_at: nil)
      @error_code = error_code
      @provider_code = provider_code
      @retry_after_at = retry_after_at
      super(error_code)
    end
  end

  class ProviderOutcomeUnknownError < StandardError; end

  def initialize(channel, api_client: nil, phone_number_id: nil)
    @channel = channel
    @api_client = api_client || Whatsapp::FacebookApiClient.new(channel.provider_config['api_key'])
    @phone_number_id = phone_number_id || channel.provider_config['phone_number_id']
  end

  def perform(pin:)
    pin = pin.to_s
    validate_pin!(pin)
    validate_registration_required!
    enforce_cooldown!
    persist_attempt!(pin)
    register_with_provider(pin)
    persist_provider_success!(pin)
    true
  rescue Error => e
    persist_failure!(e) if e.error_code == 'rate_limited'
    raise
  rescue Whatsapp::FacebookApiClient::Error => e
    failure = provider_failure(e)
    persist_failure!(failure)
    raise failure
  rescue ProviderOutcomeUnknownError
    failure = Error.new(error_code: 'outcome_unknown')
    persist_failure!(failure)
    raise failure
  end

  def automatic_retry_blocked?
    BLOCKING_AUTOMATIC_STATUSES.include?(current_state['status'])
  end

  def reconcile_from_health!(pending:, active:, probe_started_at:)
    state = current_state
    return false unless AMBIGUOUS_STATUSES.include?(state['status'])
    return false unless health_probe_can_reconcile?(state, probe_started_at)
    return reconcile_pending! if pending
    return reconcile_active! if active

    false
  end

  private

  def register_with_provider(pin)
    @api_client.register_phone_number(phone_number_id, pin)
  rescue Whatsapp::FacebookApiClient::Error
    raise
  rescue StandardError => e
    raise ProviderOutcomeUnknownError, e.message
  end

  def persist_provider_success!(pin)
    persist_success!(pin)
  rescue StandardError => e
    raise Error.new(error_code: 'outcome_unknown'), cause: e
  end

  def validate_pin!(pin)
    return if pin.match?(/\A\d{6}\z/)

    raise Error.new(error_code: 'invalid_pin')
  end

  def validate_registration_required!
    status = current_state['status']
    raise Error.new(error_code: 'registration_not_required') if status == 'registered'
    raise Error.new(error_code: 'outcome_unknown') if AMBIGUOUS_STATUSES.include?(status)

    true
  end

  def enforce_cooldown!
    state = current_state
    retry_after_at = parse_time(state['retry_after_at'])
    raise_rate_limited!(retry_after_at) if retry_after_at.present? && retry_after_at > Time.current

    attempts = recent_attempts(state)
    return if attempts.size < MAX_REGISTRATION_ATTEMPTS

    raise_rate_limited!(attempts.first + RATE_LIMIT_WINDOW)
  end

  def phone_number_id
    @phone_number_id.presence || raise(ArgumentError, 'Phone number ID is required')
  end

  def provider_failure(error)
    payload = error.payload.to_h.with_indifferent_access
    provider_error = (payload[:error] || payload).to_h.with_indifferent_access
    provider_code = provider_error[:code].presence&.to_i
    error_code = PROVIDER_ERROR_CODES.fetch(provider_code, 'registration_failed')
    retry_after_at = Time.current + RATE_LIMIT_WINDOW if error_code == 'rate_limited'

    Error.new(error_code: error_code, provider_code: provider_code, retry_after_at: retry_after_at)
  end

  def persist_attempt!(pin)
    now = Time.current
    mutate_provider_config! do |config|
      state = config[CONFIG_KEY].to_h
      attempts = recent_attempts(state, now: now) << now
      config[CONFIG_KEY] = state.except('provider_error_code', 'failed_at', 'retry_after_at').merge(
        'status' => 'registering',
        'attempted_at' => now.iso8601,
        'attempt_window_started_at' => attempts.first.iso8601,
        'attempt_count' => attempts.size,
        'attempt_timestamps' => attempts.map(&:iso8601),
        PENDING_PIN_CIPHERTEXT_KEY => encrypt_pin(pin)
      )
    end
  end

  def persist_success!(pin)
    mutate_provider_config! do |config|
      config[VERIFIED_PIN_KEY] = pin
      config[CONFIG_KEY] = config[CONFIG_KEY].to_h.except(
        'provider_error_code', 'failed_at', 'retry_after_at', PENDING_PIN_CIPHERTEXT_KEY
      ).merge('status' => 'registered', 'completed_at' => Time.current.iso8601)
    end
  end

  def persist_failure!(error)
    now = Time.current
    mutate_provider_config! do |config|
      registration = config[CONFIG_KEY].to_h
      if error.error_code == 'pin_incorrect'
        config.delete(VERIFIED_PIN_KEY)
        registration.delete(PENDING_PIN_CIPHERTEXT_KEY)
      end
      config[CONFIG_KEY] = registration.merge(
        'status' => error.error_code,
        'provider_error_code' => error.provider_code,
        'failed_at' => now.iso8601,
        'retry_after_at' => error.retry_after_at&.iso8601
      ).compact
    end
  end

  def current_state
    @channel.reload.provider_config.to_h[CONFIG_KEY].to_h
  end

  def recent_attempts(state, now: Time.current)
    attempts = Array(state['attempt_timestamps']).filter_map { |value| parse_time(value) }
    attempts = legacy_attempts(state) if attempts.empty?
    attempts.select { |attempted_at| attempted_at > now - RATE_LIMIT_WINDOW }
            .sort
            .last(MAX_REGISTRATION_ATTEMPTS)
  end

  def legacy_attempts(state)
    count = [state['attempt_count'].to_i, MAX_REGISTRATION_ATTEMPTS].min
    attempted_at = parse_time(state['attempted_at']) || parse_time(state['attempt_window_started_at'])
    attempted_at.present? ? Array.new(count, attempted_at) : []
  end

  def raise_rate_limited!(retry_after_at)
    raise Error.new(error_code: 'rate_limited', provider_code: 133_016, retry_after_at: retry_after_at)
  end

  def encrypt_pin(pin)
    pin_encryptor.encrypt_and_sign(pin, purpose: PIN_PURPOSE)
  end

  def health_probe_can_reconcile?(state, probe_started_at)
    transition_at = parse_time(state[state['status'] == 'registering' ? 'attempted_at' : 'failed_at'])
    return false if transition_at.blank? || probe_started_at.blank?

    probe_started_at >= transition_at + HEALTH_RECONCILIATION_GRACE
  end

  def reconcile_pending!
    mutate_provider_config! do |config|
      registration = config[CONFIG_KEY].to_h
      next false unless AMBIGUOUS_STATUSES.include?(registration['status'])

      registration = registration.except(PENDING_PIN_CIPHERTEXT_KEY)
      config[CONFIG_KEY] = registration.merge('status' => 'registration_incomplete', 'detected_at' => Time.current.iso8601)
      true
    end
  end

  def reconcile_active!
    mutate_provider_config! do |config|
      registration = config[CONFIG_KEY].to_h
      next false unless AMBIGUOUS_STATUSES.include?(registration['status'])

      config[CONFIG_KEY] = registration.except(
        'provider_error_code', 'failed_at', 'retry_after_at', PENDING_PIN_CIPHERTEXT_KEY
      ).merge('status' => 'registered', 'completed_at' => Time.current.iso8601)
      true
    end
  end

  def pin_encryptor
    @pin_encryptor ||= begin
      key = Rails.application.key_generator.generate_key(PIN_PURPOSE, ActiveSupport::MessageEncryptor.key_len(PIN_CIPHER))
      ActiveSupport::MessageEncryptor.new(key, cipher: PIN_CIPHER)
    end
  end

  def mutate_provider_config!
    changed = @channel.with_lock do
      @channel.reload
      config = @channel.provider_config.to_h.deep_dup
      next false unless yield config

      @channel.persist_provider_config_state!(config)
      true
    end
    invalidate_inbox_cache if changed
    changed
  end

  def invalidate_inbox_cache
    @channel.inbox&.update_account_cache
  rescue StandardError => e
    Rails.logger.warn("[WHATSAPP] Phone registration cache invalidation failed: #{e.class}")
  end

  def parse_time(value)
    Time.zone.parse(value) if value.present?
  rescue ArgumentError
    nil
  end
end
# rubocop:enable Metrics/ClassLength
