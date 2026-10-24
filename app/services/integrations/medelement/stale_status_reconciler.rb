# MedElement sets the final status of a reception (completed, cancelled, no-show) after the visit, but the regular sync
# only re-reads receptions of the last few days. This re-reads the older appointments that are still scheduled or
# confirmed, one reception at a time, and applies the status MedElement gives, and nothing else of the reception: the
# contact, client fields, services, times, resource, cabinet and payments of an old appointment stay as they are
# (ReceptionsSyncService#apply_reported_status!). The status mapping is the importer's own and nothing new decides a status.
# A reception that MedElement reports as removed goes the way a polled removal goes.
#
# An appointment that OneLink has is OneLink's whatever specialist the detail names, so the specialist and the cabinet are
# not asked for: an appointment whose detail names a specialist that is not mapped is reported, and its status applied.
#
# A dry run reads the same receptions and reports what would change, per old status and provider status, and writes
# nothing. An appointment that MedElement no longer has is never deleted or changed: it is only reported.
class Integrations::Medelement::StaleStatusReconciler
  # A reason to end the run (the message). The locks raise it too.
  Abort = Integrations::Medelement::StaleStatusLocks::Unavailable

  OPEN_STATUSES = %w[scheduled confirmed].freeze
  AUTOMATION_EVENTS = %w[appointment_updated appointment_completed appointment_cancelled].freeze
  STALE_AFTER = 1.day
  DEFAULT_DAYS = 30
  DEFAULT_BATCH_SIZE = 50
  # Bounds one run. Every appointment that MedElement closes drops out of the selection, so a backlog longer than the cap
  # is worked off over several nights. Appointments that MedElement keeps open are read again by every run.
  DEFAULT_MAX_PER_RUN = 1000
  MAX_CONSECUTIVE_PROVIDER_ERRORS = 5
  PROVIDER_ERROR_PAUSE_SECONDS = 5
  PROVIDER_ERRORS = [
    Integrations::Medelement::Client::ApiError,
    Integrations::Medelement::ProviderScope::MismatchError
  ].freeze
  # The refusals for a single reception; the regular sync and the polled changes skip such a reception the same way.
  SKIPPED_ERRORS = Integrations::Medelement::ReceptionsDeltaService::SKIPPED_ERRORS

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
    @locks = Integrations::Medelement::StaleStatusLocks.new(hook: hook, sleeper: @sleeper)
    @cursor = nil
    @consecutive_errors = 0
    @provider_read_made = false
  end

  def perform
    if eligible?
      # A dry run only reads, so it takes no lock and cannot hold a real run back.
      dry_run ? run : locks.hold_run { run }
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

  attr_reader :hook, :client, :configuration, :days, :dry_run, :batch_size, :max_per_run, :sleeper, :report, :locks

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
      locks.renew_run! unless dry_run
    end
  end

  def pending
    @cursor ? candidates.where('id < ?', @cursor) : candidates
  end

  def finish
    report.last_id = @cursor
    report.remaining = pending.count
    report.automation_rules = automation_rules
    report
  end

  def process(appointment)
    report.examine!
    throttle
    detail = fetch_detail(appointment)
    if detail.nil?
      report.not_found!(appointment.id)
    else
      report.unmapped_specialist! unless sync_service.specialist_mapped?(detail)
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
    status == :absent ? report.skipped!('absent') : record_transition(appointment.status, status)
  end

  # The visit is long over, so the status is applied as a data correction: no automation rule, CRM re-evaluation or
  # touch scheduling reacts to it (see Current.with_medelement_reconciliation). Only this status change runs inside the flag.
  def apply(appointment, detail)
    locks.hold_sync do
      before = current_status(appointment)
      next report.skipped!('no_longer_open') unless OPEN_STATUSES.include?(before)

      result = Current.with_medelement_reconciliation do
        sync_service.apply_reported_status!(detail, only_from: OPEN_STATUSES)
      end
      record_applied(before, appointment, result)
    end
  rescue *SKIPPED_ERRORS => e
    report.skipped!(e.class.name.demodulize)
  end

  def record_applied(before, appointment, result)
    # The status was not applied, and the reason is given (the appointment is gone, or no longer open, or changed locally).
    return report.skipped!(result.to_s) if result.is_a?(Symbol)

    record_transition(before, current_status(appointment))
  end

  def record_transition(from, to)
    report.transition!(from, to)
    return if from == to

    # Shown for information: the rules that listen to these events would have run for a normal status change.
    events = ['appointment_updated', "appointment_#{to}"]
    report.automation_match! if events.intersect?(automation_rules.keys)
  end

  def automation_rules
    @automation_rules ||= AutomationRule.where(account_id: hook.account_id, active: true, event_name: AUTOMATION_EVENTS)
                                        .group(:event_name).count
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

  def log_result
    Rails.logger.info("[MEDELEMENT::STALE_STATUS] hook=#{hook.id} #{report.log_line}")
    return if report.not_found_appointment_ids.empty?

    Rails.logger.warn("[MEDELEMENT::STALE_STATUS] hook=#{hook.id} not_found_appointment_ids=#{report.not_found_appointment_ids.inspect}")
  end
end
