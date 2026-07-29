class Integrations::Medelement::ProviderCommandPayloadBuilder
  class << self
    def build(command)
      command_payload(command).merge(
        reconciliation_payload(command),
        lifecycle_payload(command),
        confirmation: confirmation_payload(command.confirmation_request)
      )
    end

    private

    def command_payload(command)
      {
        id: command.id,
        operation: command.operation,
        status: command.status,
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
        reconciliation_cancellable: command.reconciliation_required?
      }
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
  end
end
