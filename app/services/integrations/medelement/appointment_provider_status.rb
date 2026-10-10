class Integrations::Medelement::AppointmentProviderStatus
  ATTRIBUTE_KEY = 'medelement_provider_sync_status'.freeze
  COMMAND_ID_KEY = 'medelement_provider_command_id'.freeze
  COMMAND_IDEMPOTENCY_KEY = 'medelement_provider_command_idempotency_key'.freeze
  COMMAND_FINGERPRINT_KEY = 'medelement_provider_command_fingerprint'.freeze
  COMMAND_DISPATCH_IDENTITY_KEY = 'medelement_provider_command_dispatch_identity'.freeze
  CANCELLATION_COMMAND_ID_KEY = 'medelement_cancellation_command_id'.freeze
  OPERATION_KEY = 'medelement_provider_operation'.freeze
  COMMAND_BINDING_KEYS = [COMMAND_ID_KEY, COMMAND_IDEMPOTENCY_KEY, COMMAND_FINGERPRINT_KEY, COMMAND_DISPATCH_IDENTITY_KEY].freeze
  PENDING = 'pending'.freeze
  SUCCEEDED = 'succeeded'.freeze
  UNKNOWN = 'provider_status_unknown'.freeze
  FAILED = 'failed'.freeze

  class << self
    def assign_pending!(appointment)
      assign!(appointment, PENDING)
      COMMAND_BINDING_KEYS.each { |key| appointment.custom_attributes.delete(key) }
      appointment.custom_attributes.delete(OPERATION_KEY)
      appointment.custom_attributes.delete(CANCELLATION_COMMAND_ID_KEY) if appointment.status == 'cancelled'
    end

    def persist!(appointment, status, command: nil)
      return if appointment.blank?

      attrs = appointment.custom_attributes.to_h
      return if attrs[ATTRIBUTE_KEY] == status && command_current?(appointment, command) &&
                (command.blank? || attrs[OPERATION_KEY] == command.operation)

      appointment.mark_medelement_provider_reconciled!
      appointment.update!(custom_attributes: attributes(appointment, status, command))
    end

    def persist_if_bound!(appointment, status, command:)
      return if appointment.blank?

      appointment.with_lock do
        persist!(appointment, status, command: command) if bound_to_command?(appointment, command)
      end
    end

    def bound_to_command?(appointment, command)
      command.present? && appointment.custom_attributes.to_h[COMMAND_ID_KEY].present? && command_current?(appointment, command)
    end

    def payload(appointment)
      if appointment.status == 'cancelled' && Integrations::Medelement::LocalCancellation.marked?(appointment)
        return {
          provider_confirmation_status: 'not_requested', provider_confirmed: false,
          provider_confirmation_operation: 'remove_reception', provider_confirmation_scope: 'onelink'
        }
      end

      status = appointment.custom_attributes.to_h[ATTRIBUTE_KEY].presence
      return {} if status.blank?

      confirmed = provider_confirmed?(appointment, status)
      {
        provider_confirmation_status: status == SUCCEEDED && !confirmed ? 'not_confirmed' : status,
        provider_confirmed: confirmed,
        provider_confirmation_operation: confirmation_operation(appointment),
        provider_confirmation_scope: 'medelement'
      }
    end

    def cancellation_confirmed?(appointment)
      attrs = appointment.custom_attributes.to_h
      return false if Integrations::Medelement::LocalCancellation.marked?(attrs)

      authoritative_reason = attrs.dig('provider_status_audit', 'reason')
      return true if authoritative_reason.in?(%w[provider_removed provider_explicit_cancelled missing_from_two_authoritative_snapshots])

      attrs[ATTRIBUTE_KEY] == SUCCEEDED && attrs[COMMAND_ID_KEY].present? &&
        attrs[CANCELLATION_COMMAND_ID_KEY].to_s == attrs[COMMAND_ID_KEY].to_s &&
        attrs[OPERATION_KEY].in?([nil, 'remove_reception'])
    end

    def public_status(appointment)
      return appointment.status if appointment.status == 'cancelled' && Integrations::Medelement::LocalCancellation.marked?(appointment)

      case appointment.custom_attributes.to_h[ATTRIBUTE_KEY]
      when PENDING then 'pending_provider_confirmation'
      when UNKNOWN then UNKNOWN
      when FAILED then 'provider_confirmation_failed'
      else appointment.status
      end
    end

    def command_attributes(command)
      state = command.execution_state.to_h
      {
        COMMAND_ID_KEY => command.id,
        COMMAND_IDEMPOTENCY_KEY => command.idempotency_key,
        COMMAND_FINGERPRINT_KEY => state['request_fingerprint'],
        COMMAND_DISPATCH_IDENTITY_KEY => state['dispatch_identity'],
        OPERATION_KEY => command.operation
      }.tap { |values| values[CANCELLATION_COMMAND_ID_KEY] = command.id if command.remove_reception? }
    end

    private

    def provider_confirmed?(appointment, status)
      status == SUCCEEDED && (appointment.status != 'cancelled' || cancellation_confirmed?(appointment))
    end

    def confirmation_operation(appointment)
      return 'remove_reception' if appointment.status == 'cancelled'

      appointment.custom_attributes.to_h[OPERATION_KEY]
    end

    def assign!(appointment, status)
      appointment.custom_attributes = attributes(appointment, status)
    end

    def attributes(appointment, status, command = nil)
      appointment.custom_attributes.to_h.merge(ATTRIBUTE_KEY => status).merge(command.present? ? command_attributes(command) : {})
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
