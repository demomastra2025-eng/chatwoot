class Scheduling::Appointments::MutationGuard
  PROVIDER_SOURCE = 'medelement'.freeze
  PROVIDER_EXTERNAL_REF_PREFIX = 'medelement:'.freeze
  LOCAL_PROVIDER_APPOINTMENT_PARAM_KEYS = %i[client_comment custom_attributes].freeze

  class << self
    def ensure_editable!(appointment, params = nil)
      return unless appointment.source == PROVIDER_SOURCE
      return if local_provider_appointment_mutation?(params)

      raise Scheduling::Error.new(
        code: 'APPOINTMENT_READ_ONLY',
        message: 'Imported Medelement appointments are read-only',
        status: :unprocessable_content
      )
    end

    def local_provider_appointment_mutation?(params)
      return false if params.nil?

      normalized = params.to_h.deep_symbolize_keys
      return false if normalized.empty? || (normalized.keys - LOCAL_PROVIDER_APPOINTMENT_PARAM_KEYS).any?

      custom_attributes = normalized[:custom_attributes]
      custom_attributes.nil? || !custom_attributes.to_h.stringify_keys.key?('medelement_cabinet_code')
    end

    def ensure_assignable!(params)
      ensure_source_not_assigned!(params)
      ensure_external_ref_not_reserved!(params)
    end

    private

    def ensure_source_not_assigned!(params)
      return unless params.key?(:source)

      raise Scheduling::Error.new(
        code: 'APPOINTMENT_SOURCE_READ_ONLY',
        message: 'Appointment source is managed by the system',
        status: :unprocessable_content
      )
    end

    def ensure_external_ref_not_reserved!(params)
      normalized_external_ref = params[:external_ref].to_s.strip
      return unless normalized_external_ref.start_with?(PROVIDER_EXTERNAL_REF_PREFIX)

      raise Scheduling::Error.new(
        code: 'APPOINTMENT_EXTERNAL_REF_RESERVED',
        message: 'Medelement external references are reserved for provider synchronization',
        status: :unprocessable_content
      )
    end
  end
end
