class Integrations::Medelement::ProviderCommandPayloadBuilder
  class << self
    def build(command)
      command_payload(command).merge(
        reconciliation_payload(command),
        lifecycle_payload(command),
        patient_action: patient_action_payload(command),
        confirmation: confirmation_payload(command.confirmation_request)
      )
    end

    private

    def command_payload(command)
      {
        id: command.id,
        operation: command.operation,
        status: command.logical_status,
        idempotency_key: command.idempotency_key,
        requested_by: command.request_snapshot.to_h['actor'],
        terminal: command.status.in?(Integrations::Medelement::ProviderCommand::TERMINAL_STATUSES),
        appointment_id: command.appointment_id,
        contact_id: command.contact_id,
        provider_reception_code: command.provider_reception_code,
        company_cabinet_code: command.company_cabinet_code,
        desired_starts_at: command.desired_starts_at&.iso8601,
        desired_ends_at: command.desired_ends_at&.iso8601,
        attempt_count: command.attempt_count
      }
    end

    def reconciliation_payload(command)
      {
        reconciliation_attempts: command.reconciliation_attempts,
        reconciliation_next_at: command.reconciliation_next_at&.iso8601,
        cancellation_review_candidates: Array(command.execution_state.to_h['cancelled_reception_candidate_codes']),
        manual_cancellation_available: Integrations::Medelement::ProviderCommands::ManualCancellationPolicy.available?(command),
        manual_cancellation_reception_code: manual_cancellation_reception_code(command),
        manual_cancellation_resolution: command.execution_state.to_h['manual_cancellation_resolution'],
        reconciliation_cancellable: command.reconciliation_required? &&
          Integrations::Medelement::ProviderCommands::CancelService.cancellable?(command)
      }
    end

    def manual_cancellation_reception_code(command)
      policy = Integrations::Medelement::ProviderCommands::ManualCancellationPolicy
      policy.reception_codes(command).first if policy.available?(command)
    end

    def lifecycle_payload(command)
      {
        last_error_code: command.last_error_code,
        last_error_status: command.last_error_status,
        confirmed_at: command.confirmed_at&.iso8601,
        executed_at: command.executed_at&.iso8601,
        created_at: command.created_at.iso8601,
        updated_at: command.updated_at.iso8601
      }
    end

    def confirmation_payload(confirmation_request)
      return if confirmation_request.blank?

      {
        id: confirmation_request.id,
        status: confirmation_request.status,
        expires_at: confirmation_request.expires_at&.iso8601
      }
    end

    def patient_action_payload(command)
      if command.failed? && Integrations::Medelement::ProviderCommands::PatientActionsService.selection_available?(command)
        return { 'type' => 'patient_selection', 'cancellable' => false, 'can_confirm' => true, 'requires_patient_card_confirmation' => true }
      end
      return unless command.logical_status.in?(Integrations::Medelement::ProviderCommands::PatientActionRequired::STATUSES)

      command.execution_state.to_h['patient_action'].to_h.merge(
        'cancellable' => Integrations::Medelement::ProviderCommands::CancelService.cancellable?(command)
      )
    end
  end
end
