# Asks MedElement whether the fast "receptions changed since" endpoint answers for one clinic, and switches the hook's
# incremental_receptions_enabled setting to match. The request covers only the last hour and nothing it returns is applied.
#
#   available       a valid answer: fast sync is switched on
#   unavailable     401, 403 or 404: the clinic cannot use it, so fast sync is switched off and full sync carries on alone
#   transient_error timeout, network, 429 or 5xx: nothing changes, the next probe tries again
#   error           any other refusal (for example 400) or a response of another organization: nothing changes
#
# The last result is kept in the hook settings under delta_probe (time, outcome, error code) for the status presenter.
class Integrations::Medelement::DeltaProbeService
  FLAG_KEY = 'incremental_receptions_enabled'.freeze
  RESULT_KEY = 'delta_probe'.freeze
  WINDOW = 1.hour
  UNAVAILABLE_STATUSES = [401, 403, 404].freeze

  def initialize(hook:, client: nil, configuration: nil)
    @hook = hook
    @configuration = configuration || Integrations::Medelement::Configuration.new(hook: hook)
    # A background probe must not sit in the long read retries of a failing provider: the next probe is the retry.
    @client = client || Integrations::Medelement::Client.new(configuration: @configuration, retry_profile: :command)
  end

  # Returns the outcome, or nil when this hook is not probed at all.
  def perform
    return unless probe_due?

    outcome, error_code = probe
    record!(outcome, error_code)
    outcome
  end

  private

  attr_reader :hook, :configuration, :client

  def probe_due?
    hook.enabled? && hook.feature_allowed? && configuration.sync_receptions? && configuration.delta_probe_enabled?
  end

  def probe
    client.receptions_by_update_date(update_date_from: window_start)
    ['available', nil]
  rescue Integrations::Medelement::Client::ApiError => e
    [error_outcome(e), error_code(e)]
  rescue Integrations::Medelement::ProviderScope::MismatchError
    ['error', 'provider_scope_mismatch']
  end

  def window_start
    (Time.current - WINDOW).in_time_zone(configuration.time_zone).strftime('%d.%m.%Y %H:%M')
  end

  def error_outcome(error)
    return 'unavailable' if UNAVAILABLE_STATUSES.include?(error.status)

    error.retryable? ? 'transient_error' : 'error'
  end

  def error_code(error)
    return "http_#{error.status}" if error.status.present?

    error.class.name.demodulize.underscore
  end

  def record!(outcome, error_code)
    target = target_flag(outcome)
    flipped = !target.nil? && target != configuration.incremental_receptions_enabled?
    write!(flipped ? { FLAG_KEY => target } : {}, outcome, error_code)
    # Fast sync was off, so its full-sweep backoff cannot be trusted: start from the shortest interval again.
    Integrations::Medelement::DeltaMissAudit.new(hook: hook).reset_full_sweep_backoff!(reason: 'delta_probe_enabled') if flipped && target
    # Creates the delta cron job after an enable and removes it after a disable (also when the flag did not change).
    Integrations::Medelement::CronScheduleService.new(hook: hook).sync! unless target.nil?
  end

  def target_flag(outcome)
    case outcome
    when 'available' then true
    when 'unavailable' then false
    end
  end

  # One atomic merge of the changed keys: a settings edit made at the same moment cannot be overwritten, and the hook
  # callbacks stay out of it (the cron sync is done explicitly above).
  def write!(changes, outcome, error_code)
    result = { 'checked_at' => Time.current.utc.iso8601, 'outcome' => outcome, 'error_code' => error_code }.compact
    # rubocop:disable Rails/SkipsModelValidations
    Integrations::Hook.where(id: hook.id).update_all(
      ["settings = COALESCE(settings, '{}'::jsonb) || ?::jsonb, updated_at = ?",
       changes.merge(RESULT_KEY => result).to_json, Time.current]
    )
    # rubocop:enable Rails/SkipsModelValidations
    hook.reload
  end
end
