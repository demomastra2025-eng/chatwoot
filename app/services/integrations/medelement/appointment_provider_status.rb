class Integrations::Medelement::AppointmentProviderStatus
  ATTRIBUTE_KEY = 'medelement_provider_sync_status'.freeze
  PENDING = 'pending'.freeze
  SUCCEEDED = 'succeeded'.freeze
  UNKNOWN = 'provider_status_unknown'.freeze
  FAILED = 'failed'.freeze

  class << self
    def assign_pending!(appointment)
      assign!(appointment, PENDING)
    end

    def persist!(appointment, status)
      return if appointment.blank?
      return if appointment.custom_attributes.to_h[ATTRIBUTE_KEY] == status

      appointment.mark_medelement_provider_reconciled!
      appointment.update!(custom_attributes: attributes(appointment, status))
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

    def attributes(appointment, status)
      appointment.custom_attributes.to_h.merge(ATTRIBUTE_KEY => status)
    end
  end
end
