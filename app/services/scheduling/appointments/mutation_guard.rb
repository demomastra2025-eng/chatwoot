class Scheduling::Appointments::MutationGuard
  PROVIDER_SOURCE = 'medelement'.freeze
  PROVIDER_EXTERNAL_REF_PREFIX = 'medelement:'.freeze

  class << self
    def ensure_editable!(appointment)
      return unless appointment.source == PROVIDER_SOURCE

      raise Scheduling::Error.new(
        code: 'APPOINTMENT_READ_ONLY',
        message: 'Imported Medelement appointments are read-only',
        status: :unprocessable_content
      )
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
