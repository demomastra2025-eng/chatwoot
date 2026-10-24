# MedElement sets the final status of a reception (completed, cancelled, no-show) after the visit, but the regular sync
# only re-reads receptions of the last few days. This re-reads the older appointments that are still scheduled or
# confirmed, one reception at a time, and applies what MedElement says through the import path of a polled change
# (ReceptionsDeltaService#apply_detail!), so the status mapping is the importer's own and nothing new decides a status.
#
# A dry run reads the same receptions and reports what would change, per old status and provider status, and writes
# nothing. An appointment that MedElement no longer has is never deleted or changed: it is only reported.
class Integrations::Medelement::StaleStatusReconciler
  Abort = Class.new(StandardError)

  OPEN_STATUSES = %w[scheduled confirmed].freeze
  STALE_AFTER = 1.day
  DEFAULT_DAYS = 30
  DEFAULT_BATCH_SIZE = 50
  # Bounds one run. Every appointment that MedElement closes drops out of the selection, so a backlog longer than the cap
  # is worked off over several nights. Appointments that MedElement keeps open are read again by every run.
  DEFAULT_MAX_PER_RUN = 1000
  MAX_CONSECUTIVE_PROVIDER_ERRORS = 5
  PROVIDER_ERROR_PAUSE_SECONDS = 5
  RUN_LOCK_LEASE = 30.minutes
  SYNC_LOCK_LEASE = 2.minutes
  SYNC_LOCK_ATTEMPTS = 24
  SYNC_LOCK_PAUSE_SECONDS = 5
  PROVIDER_ERRORS = [
    Integrations::Medelement::Client::ApiError,
    Integrations::Medelement::ProviderScope::MismatchError
  ].freeze
  # The refusals of the importer for a single reception; the regular sync skips such a reception the same way.
  SKIPPED_ERRORS = [
    Integrations::Medelement::AppointmentSnapshotGuard::StaleSnapshotError,
    Integrations::Medelement::ReceptionsSyncService::InvalidReceptionError,
    Integrations::Medelement::ReceptionServiceRows::InvalidSnapshotError,
    ActiveRecord::RecordInvalid,
    Scheduling::Error
  ].freeze

  # days: how far back to look, nil for the whole history. max_per_run: nil for no cap.
  def initialize(hook:, client: nil, configuration: nil, **options)
    @hook = hook
    @configuration = configuration || Integrations::Medelement::Configuration.new(hook: hook)
    # A long background run must not sit in the long read retries of a failing provider: the run gives up after a few
    # consecutive failures and the next run tries again.
    @client = client || Integrations::Medelement::Client.new(configuration: @configuration, retry_profile: :command)
    @days = options.fetch(:days, DEFAULT_DAYS)
    @dry_run = options.fetch(:dry_run, false)
    @batch_size = options.fetch(:batch_size, DEFAULT_BATCH_SIZE)
    @max_per_run = options.fetch(:max_per_run, DEFAULT_MAX_PER_RUN) || Float::INFINITY
    @sleeper = options.fetch(:sleeper) { ->(seconds) { Kernel.sleep(seconds) } }
    @report = Integrations::Medelement::StaleStatusReport.new(dry_run: @dry_run, days: @days)
    @cursor = nil
    @consecutive_errors = 0
    @provider_read_made = false
  end

  def perform
    if eligible?
      # A dry run only reads, so it takes no lock and cannot hold a real run back.
      dry_run ? run : with_run_lock { run }
    else
      report.aborted = 'not_eligible'
    end
    finish
  rescue Abort => e
    report.aborted = e.message
    finish
  ensure
    log_result
  end

  private

  attr_reader :hook, :client, :configuration, :days, :dry_run, :batch_size, :max_per_run, :sleeper, :report

  def eligible?
    hook.enabled? && hook.feature_allowed? && configuration.sync_receptions?
  end

  def candidates
    from = days&.days&.ago
    hook.account.scheduling_appointments
        .where(source: Integrations::Medelement::AppointmentImporterService::MEDELEMENT_SOURCE, status: OPEN_STATUSES)
        .where('external_ref LIKE ?', "#{Integrations::Medelement::AppointmentImporterService::RECEPTION_EXTERNAL_REF_PREFIX}%")
        .where(starts_at: from..STALE_AFTER.ago)
  end

  # Newest first: the appointments that just passed are the ones MedElement is about to close, and a capped run should
  # reach them before the old ones that MedElement keeps open.
  def run
    while report.examined < max_per_run
      batch = pending.order(id: :desc).limit([batch_size, max_per_run - report.examined].min).to_a
      break if batch.empty?

      batch.each { |appointment| process(appointment) }
      renew_run_lock!
    end
  end

  def pending
    @cursor ? candidates.where('id < ?', @cursor) : candidates
  end

  def finish
    report.last_id = @cursor
    report.remaining = pending.count
    report
  end

  def process(appointment)
    report.examine!
    throttle
    detail = fetch_detail(appointment)
    if detail.nil?
      report.not_found!(appointment.id)
    else
      dry_run ? preview(appointment, detail) : apply(appointment, detail)
    end
    @consecutive_errors = 0
  rescue *PROVIDER_ERRORS => e
    provider_error!(e)
  ensure
    @cursor = appointment.id
  end

  # One request per throttle_ms, as every other MedElement caller of this clinic.
  def throttle
    sleeper.call(configuration.throttle_ms / 1000.0) if @provider_read_made
    @provider_read_made = true
  end

  # nil when MedElement does not have the reception.
  def fetch_detail(appointment)
    code = appointment.external_ref.delete_prefix(Integrations::Medelement::AppointmentImporterService::RECEPTION_EXTERNAL_REF_PREFIX)
    detail = client.get_reception(reception_code: code, version: :v2)
    return unless detail.is_a?(Hash) && detail['RECEPTION_CODE'].to_s == code

    delta.validate_detail!(detail, code)
    detail
  rescue Integrations::Medelement::Client::ApiError => e
    raise unless e.status == 404
  end

  def preview(appointment, detail)
    status = sync_service.preview_reported_status(detail)
    case status
    when :out_of_scope then report.out_of_scope!
    when :absent then report.skipped!('absent')
    else report.transition!(appointment.status, status)
    end
  end

  def apply(appointment, detail)
    with_sync_lock do
      before = current_status(appointment)
      next report.skipped!('no_longer_open') unless OPEN_STATUSES.include?(before)

      record_applied(before, appointment, delta.apply_detail!(detail))
    end
  rescue *SKIPPED_ERRORS => e
    report.skipped!(e.class.name.demodulize)
  end

  def record_applied(before, appointment, result)
    return report.out_of_scope! if result == :out_of_scope
    # The import refused the reception on its own grounds (for example a newer local change), and said why.
    return report.skipped!(result.to_s) if result.is_a?(Symbol)

    report.transition!(before, current_status(appointment))
  end

  def current_status(appointment)
    Scheduling::Appointment.where(id: appointment.id).pick(:status)
  end

  def provider_error!(error)
    report.error!(error.status ? "http_#{error.status}" : error.class.name.demodulize.underscore)
    @consecutive_errors += 1
    raise Abort, 'provider_errors' if @consecutive_errors >= MAX_CONSECUTIVE_PROVIDER_ERRORS

    sleeper.call(PROVIDER_ERROR_PAUSE_SECONDS)
  end

  def delta
    @delta ||= Integrations::Medelement::ReceptionsDeltaService.new(hook: hook, client: client, configuration: configuration)
  end

  def sync_service
    @sync_service ||= Integrations::Medelement::ReceptionsSyncService.new(
      account: hook.account, client: client, configuration: configuration
    )
  end

  # One run per hook at a time.
  def with_run_lock
    @run_lock_key = format(::Redis::Alfred::MEDELEMENT_STALE_STATUS_MUTEX, hook_id: hook.id)
    @run_lock = ::Redis::LockManager.new
    raise Abort, 'already_running' unless @run_lock.lock(@run_lock_key, RUN_LOCK_LEASE)

    begin
      yield
    ensure
      @run_lock.unlock(@run_lock_key)
    end
  end

  def renew_run_lock!
    return if dry_run
    return if @run_lock.renew(@run_lock_key, RUN_LOCK_LEASE)

    raise Abort, 'lock_lost'
  end

  # The account's sync mutex, held for one import at a time only, so the regular sync and the delta poll are never kept
  # waiting for more than a moment. A sync that holds it for longer ends the run; the next run continues.
  def with_sync_lock
    key = format(::Redis::Alfred::MEDELEMENT_SYNC_MUTEX, account_id: hook.account_id)
    lock = ::Redis::LockManager.new
    attempts = 0
    until lock.lock(key, SYNC_LOCK_LEASE)
      attempts += 1
      raise Abort, 'sync_busy' if attempts >= SYNC_LOCK_ATTEMPTS

      sleeper.call(SYNC_LOCK_PAUSE_SECONDS)
    end

    begin
      yield
    ensure
      lock.unlock(key)
    end
  end

  def log_result
    Rails.logger.info("[MEDELEMENT::STALE_STATUS] hook=#{hook.id} #{report.log_line}")
    return if report.not_found_appointment_ids.empty?

    Rails.logger.warn("[MEDELEMENT::STALE_STATUS] hook=#{hook.id} not_found_appointment_ids=#{report.not_found_appointment_ids.inspect}")
  end
end
