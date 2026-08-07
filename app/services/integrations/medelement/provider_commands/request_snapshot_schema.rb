class Integrations::Medelement::ProviderCommands::RequestSnapshotSchema
  VERSION = 2
  SUPPORTED_VERSIONS = [1, VERSION].freeze
  class Error < StandardError; end

  class << self
    def valid?(snapshot)
      validate!(snapshot)
      true
    rescue Error
      false
    end

    def validate!(snapshot)
      version = snapshot_version(snapshot)
      validate_phone_numbers!(snapshot['patient_phone_numbers'], field: 'patient_phone_numbers') if snapshot.key?('patient_phone_numbers')
      validate_patient!(snapshot['patient'])
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

    private

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
