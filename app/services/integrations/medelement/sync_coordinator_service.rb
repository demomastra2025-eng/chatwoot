class Integrations::Medelement::SyncCoordinatorService
  SyncUnavailableError = Class.new(StandardError)

  def initialize(hook:)
    @hook = hook
    @configuration = Integrations::Medelement::Configuration.new(hook: hook)
    @client = Integrations::Medelement::Client.new(configuration: configuration)
  end

  def perform(sync_run: nil, phases: nil)
    raise SyncUnavailableError, 'Medelement integration is disabled' if hook.disabled?
    raise SyncUnavailableError, 'Scheduling feature is disabled' unless hook.feature_allowed?

    @sync_run = sync_run
    @conflict_tracker = Integrations::Medelement::ConflictTracker.new(sync_run: sync_run) if sync_run
    selected_phases(phases).each { |phase| run_phase(phase) }
    sync_run&.finish!
  end

  private

  attr_reader :client, :configuration, :conflict_tracker, :hook, :sync_run

  def selected_phases(phases)
    return Integrations::Medelement::SyncRun::PHASES if phases.nil?

    Array(phases)
  end

  def run_phase(phase)
    sync_run&.start_phase!(phase)
    result = send("sync_#{phase}")
    persist_phase_result(phase, result)
  rescue StandardError => e
    sync_run&.record_phase_failure!(phase, e)
    raise
  end

  def persist_phase_result(phase, result)
    return sync_run&.skip_phase!(phase, 'disabled_by_configuration') if result == :disabled

    sync_run&.complete_phase!(phase, result || {})
    return if phase == 'contacts'

    conflict_tracker&.resolve_absent!(phase)
  end

  def sync_setup
    Integrations::Medelement::ContactCustomAttributesSetupService.new(account: hook.account).perform
    { configured_fields: Integrations::Medelement::ContactCustomAttributesSetupService::FIELDS.size }
  end

  def sync_specialists
    return :disabled unless configuration.sync_specialists?

    Integrations::Medelement::SpecialistsSyncService.new(
      account: hook.account,
      client: client,
      configuration: configuration,
      **tracking_options
    ).perform
  end

  def sync_services
    return :disabled unless configuration.sync_services?

    Integrations::Medelement::ServicesSyncService.new(
      account: hook.account,
      client: client,
      **tracking_options
    ).perform
  end

  def sync_contacts
    return :disabled unless configuration.sync_patients?

    Integrations::Medelement::LinkedContactsSyncService.new(
      account: hook.account,
      client: client,
      conflict_tracker: conflict_tracker,
      organization_id: configuration.organization_id
    ).perform
  end

  def sync_receptions
    return :disabled unless configuration.sync_receptions?

    Integrations::Medelement::ReceptionsSyncService.new(
      account: hook.account,
      client: client,
      configuration: configuration,
      **tracking_options
    ).perform
  end

  def tracking_options
    conflict_tracker ? { conflict_tracker: conflict_tracker } : {}
  end
end
