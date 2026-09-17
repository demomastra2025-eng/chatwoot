class Integrations::Medelement::AppointmentProviderStatus
  ATTRIBUTE_KEY = 'medelement_provider_sync_status'.freeze
  COMMAND_ID_KEY = 'medelement_provider_command_id'.freeze
  COMMAND_IDEMPOTENCY_KEY = 'medelement_provider_command_idempotency_key'.freeze
  COMMAND_FINGERPRINT_KEY = 'medelement_provider_command_fingerprint'.freeze
  COMMAND_DISPATCH_IDENTITY_KEY = 'medelement_provider_command_dispatch_identity'.freeze
  CANCELLATION_COMMAND_ID_KEY = 'medelement_cancellation_command_id'.freeze
  COMMAND_BINDING_KEYS = [COMMAND_ID_KEY, COMMAND_IDEMPOTENCY_KEY, COMMAND_FINGERPRINT_KEY, COMMAND_DISPATCH_IDENTITY_KEY].freeze
  PENDING = 'pending'.freeze
  SUCCEEDED = 'succeeded'.freeze
  UNKNOWN = 'provider_status_unknown'.freeze
  FAILED = 'failed'.freeze

  class << self
    def assign_pending!(appointment)
      assign!(appointment, PENDING)
      COMMAND_BINDING_KEYS.each { |key| appointment.custom_attributes.delete(key) }
      appointment.custom_attributes.delete(CANCELLATION_COMMAND_ID_KEY) if appointment.status == 'cancelled'
    end

    def persist!(appointment, status, command: nil)
      return if appointment.blank?
      return if appointment.custom_attributes.to_h[ATTRIBUTE_KEY] == status && command_current?(appointment, command)

      appointment.mark_medelement_provider_reconciled!
      appointment.update!(custom_attributes: attributes(appointment, status, command))
    end

    def payload(appointment)
      status = appointment.custom_attributes.to_h[ATTRIBUTE_KEY].presence
      return {} if status.blank?

      {
        provider_confirmation_status: status,
        provider_confirmed: status == SUCCEEDED
      }
    end

    def public_status(appointment)
      case appointment.custom_attributes.to_h[ATTRIBUTE_KEY]
      when PENDING then 'pending_provider_confirmation'
      when UNKNOWN then UNKNOWN
      when FAILED then 'provider_confirmation_failed'
      else appointment.status
      end
    end

    private

    def assign!(appointment, status)
      appointment.custom_attributes = attributes(appointment, status)
    end

    def attributes(appointment, status, command = nil)
      appointment.custom_attributes.to_h.merge(ATTRIBUTE_KEY => status).tap do |values|
        next if command.blank?

        values[COMMAND_ID_KEY] = command.id
        values[COMMAND_IDEMPOTENCY_KEY] = command.idempotency_key
        values[COMMAND_FINGERPRINT_KEY] = command.execution_state.to_h['request_fingerprint']
        values[COMMAND_DISPATCH_IDENTITY_KEY] = command.execution_state.to_h['dispatch_identity']
        values[CANCELLATION_COMMAND_ID_KEY] = command.id if command.remove_reception?
      end
    end

    def command_current?(appointment, command)
      return true if command.blank?

      persisted_command_binding(appointment) == command_binding(command) && cancellation_command_current?(appointment, command)
    end

    def persisted_command_binding(appointment)
      attributes = appointment.custom_attributes.to_h
      COMMAND_BINDING_KEYS.index_with { |key| attributes[key].to_s }
    end

    def command_binding(command)
      state = command.execution_state.to_h
      {
        COMMAND_ID_KEY => command.id.to_s,
        COMMAND_IDEMPOTENCY_KEY => command.idempotency_key.to_s,
        COMMAND_FINGERPRINT_KEY => state['request_fingerprint'].to_s,
        COMMAND_DISPATCH_IDENTITY_KEY => state['dispatch_identity'].to_s
      }
    end

    def cancellation_command_current?(appointment, command)
      return true unless command.remove_reception?

      appointment.custom_attributes.to_h[CANCELLATION_COMMAND_ID_KEY].to_s == command.id.to_s
    end
  end
end
