class Integrations::Medelement::ProviderCommands::PendingReceptionResolver
  ELIGIBLE_LOGICAL_STATUSES = %w[processing reconciliation_required provider_status_unknown].freeze

  def initialize(account:)
    @account = account
  end

  def resolve(reception:, resource:, import_context:)
    command = matched_command(reception: reception, resource: resource, import_context: import_context)
    return if command.blank?

    adopt_reception!(command, reception)
  end

  private

  attr_reader :account

  def matched_command(reception:, resource:, import_context:)
    commands = matching_commands(reception: reception, resource: resource, import_context: import_context)
    return if commands.empty?

    if commands.many?
      raise Scheduling::Error.new(
        code: 'MEDELEMENT_RECEPTION_COMMAND_AMBIGUOUS',
        message: 'Provider reception matches more than one unfinished outbound command',
        status: :conflict
      )
    end

    commands.first
  end

  def adopt_reception!(command, reception)
    applied = Integrations::Medelement::ProviderCommands::SuccessApplier.new(command: command).reception_discovered!(
      reception_code: reception.fetch('RECEPTION_CODE').to_s,
      patient_code: provider_patient_code(reception)
    )
    return command.appointment.reload if applied

    command.reload
    return command.appointment.reload if command.succeeded? && command.appointment.external_ref == external_ref(reception)

    raise Scheduling::Error.new(
      code: 'MEDELEMENT_RECEPTION_COMMAND_BUSY',
      message: 'Provider reception is being reconciled by another worker',
      status: :conflict
    )
  end

  def matching_commands(reception:, resource:, import_context:)
    candidate_commands(reception: reception, import_context: import_context).select do |command|
      command_matches?(command, reception, resource)
    end
  end

  def candidate_commands(reception:, import_context:)
    statuses = ELIGIBLE_LOGICAL_STATUSES.flat_map do |status|
      Integrations::Medelement::ProviderCommand.execution_statuses(status)
    end

    Integrations::Medelement::ProviderCommand
      .includes(:appointment, :confirmation_request)
      .joins(:appointment)
      .where(
        account: account,
        operation: 'create_reception',
        status: statuses,
        company_cabinet_code: reception['COMPANY_CABINET_CODE'].to_s,
        desired_starts_at: import_context.fetch(:starts_at),
        desired_ends_at: import_context.fetch(:ends_at)
      )
  end

  def command_matches?(command, reception, resource)
    return false unless command.execution_state.to_h['write_phase'] == 'reception_create'
    return false unless command.request_snapshot_valid?
    return false unless command.confirmation_matches_request_snapshot?
    return false unless command.request_snapshot.dig('reception', 'resource_id').to_i == resource.id
    return false if preflight_reception_codes(command).include?(reception['RECEPTION_CODE'].to_s)

    Integrations::Medelement::ProviderCommands::ReceptionVerifier.new(
      command: command,
      provider_patient_code: command.execution_state.to_h['write_provider_patient_code']
    ).destination_match?(reception)
  rescue KeyError, Integrations::Medelement::ReceptionServiceRows::InvalidSnapshotError
    false
  end

  def preflight_reception_codes(command)
    Array(command.execution_state.to_h['preflight_reception_codes']).map(&:to_s)
  end

  def provider_patient_code(reception)
    reception['PROFILE_CODE'].presence || reception['PATIENT_CODE'].presence
  end

  def external_ref(reception)
    "medelement:reception:#{reception.fetch('RECEPTION_CODE')}"
  end
end
