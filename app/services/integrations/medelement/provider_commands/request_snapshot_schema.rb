class Integrations::Medelement::ProviderCommands::RequestSnapshotSchema
  VERSION = 2
  SUPPORTED_VERSIONS = [1, VERSION].freeze
  class Error < StandardError; end

  class DestinationIntervalError < Error
    def code = 'INVALID_DURATION'
  end

  DESTINATION_INTERVAL_MESSAGE = 'Reception duration must be a whole number of minutes from 5 to 1440'.freeze

  class << self
    def valid?(snapshot)
      validate!(snapshot)
      true
    rescue Error
      false
    end

    def validate!(snapshot)
      version = snapshot_version(snapshot)
      binding = snapshot[Integrations::Medelement::AppointmentPatientIdentity::BINDING_KEY]
      raise Error, 'patient contact binding must be a positive ID' unless binding.nil? || (binding.is_a?(Integer) && binding.positive?)

      validate_appointment_identity!(snapshot)
      validate_phone_numbers!(snapshot['patient_phone_numbers'], field: 'patient_phone_numbers') if snapshot.key?('patient_phone_numbers')
      validate_patient!(snapshot['patient'])
      validate_reception_destination!(snapshot)
      reception = snapshot['reception']
      return true if reception.nil?

      raise Error, 'reception snapshot must be an object' unless reception.is_a?(Hash)

      service_codes(snapshot, version: version)
      true
    end

    def service_codes(snapshot, version: snapshot_version(snapshot))
      reception = snapshot['reception']
      return [] if reception.nil?

      version == 1 ? legacy_service_codes(reception) : current_service_codes(reception)
    end

    def supported_destination_interval?(starts_at, ends_at)
      return false unless starts_at.respond_to?(:to_time) && ends_at.respond_to?(:to_time)

      seconds = ends_at.to_time.to_r - starts_at.to_time.to_r
      seconds.between?(Scheduling::Constants::MIN_DURATION_MINUTES * 60, Scheduling::Constants::MAX_DURATION_MINUTES * 60) &&
        (seconds % 60).zero?
    end

    def validate_destination_interval!(starts_at:, ends_at:)
      return if supported_destination_interval?(starts_at, ends_at)

      raise DestinationIntervalError, DESTINATION_INTERVAL_MESSAGE
    end

    def validate_reception_destination!(snapshot)
      return unless snapshot.is_a?(Hash) && %w[create_reception move_reception].include?(snapshot['operation'])

      reception = snapshot['reception']
      raise DestinationIntervalError, DESTINATION_INTERVAL_MESSAGE unless reception.is_a?(Hash)

      validate_destination_interval!(
        starts_at: Time.iso8601(reception['destination_starts_at']),
        ends_at: Time.iso8601(reception['destination_ends_at'])
      )
    rescue ArgumentError, TypeError
      raise DestinationIntervalError, DESTINATION_INTERVAL_MESSAGE
    end

    private

    def validate_appointment_identity!(snapshot)
      key = Integrations::Medelement::AppointmentPatientIdentity::SNAPSHOT_KEY
      return unless snapshot.key?(key)

      identity = snapshot[key]
      valid = identity.is_a?(Hash) && identity.keys.sort == %w[explicit_identifier fields owned] &&
              valid_identity_flags?(identity) && valid_identity_fields?(identity['fields'])
      raise Error, 'appointment patient identity snapshot is invalid' unless valid
    end

    def valid_identity_flags?(identity)
      [true, false].include?(identity['owned']) && [true, false].include?(identity['explicit_identifier'])
    end

    def valid_identity_fields?(values)
      fields = Integrations::Medelement::AppointmentPatientIdentity::FIELDS
      values.is_a?(Hash) && values.keys.sort == fields.sort && values.values.all? { |value| value.nil? || value.is_a?(String) }
    end

    def validate_patient!(patient)
      return if patient.nil?
      raise Error, 'patient snapshot must be an object' unless patient.is_a?(Hash)
      return unless patient.key?('phone_numbers')

      validate_phone_numbers!(patient['phone_numbers'], field: 'patient phone_numbers')
    end

    def validate_phone_numbers!(values, field:)
      raise Error, "#{field} must be an array" unless values.is_a?(Array)

      valid = values.all? do |value|
        value.is_a?(String) && Integrations::Medelement::PhoneNumber.normalize(value) == value
      end
      raise Error, "#{field} must contain normalized Kazakhstan numbers" unless valid
    end

    def snapshot_version(snapshot)
      raise Error, 'request snapshot must be an object' unless snapshot.is_a?(Hash)

      version = snapshot['version']
      return version if SUPPORTED_VERSIONS.include?(version)

      raise Error, "unsupported snapshot version: #{version.inspect}"
    end

    def legacy_service_codes(reception)
      raise Error, 'v1 reception cannot contain nomenclature_codes' if reception.key?('nomenclature_codes')

      value = reception['nomenclature_code']
      raise Error, 'v1 nomenclature_code must be scalar' if value.is_a?(Array) || value.is_a?(Hash)

      Array(value.to_s.presence)
    end

    def current_service_codes(reception)
      raise Error, 'v2 reception must contain nomenclature_codes' unless reception.key?('nomenclature_codes')

      values = reception['nomenclature_codes']
      raise Error, 'v2 nomenclature_codes must be an array' unless values.is_a?(Array)

      validate_current_values!(values)
      validate_legacy_service_code!(reception, values)
      values.map(&:to_s).uniq
    end

    def validate_current_values!(values)
      invalid = values.any? do |value|
        !(value.is_a?(String) || value.is_a?(Numeric)) || value.to_s.blank?
      end
      raise Error, 'v2 nomenclature_codes must contain non-blank scalar values' if invalid
    end

    def validate_legacy_service_code!(reception, values)
      return unless reception.key?('nomenclature_code')

      value = reception['nomenclature_code']
      raise Error, 'v2 nomenclature_code must be scalar' if value.is_a?(Array) || value.is_a?(Hash) || value.to_s.blank?
      return if value.to_s == values.first&.to_s

      raise Error, 'v2 nomenclature_code must match the first nomenclature_codes value'
    end
  end
end
