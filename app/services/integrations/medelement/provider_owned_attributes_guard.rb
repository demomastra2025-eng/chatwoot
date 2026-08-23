class Integrations::Medelement::ProviderOwnedAttributesGuard
  PREFIX = 'medelement_'.freeze
  PROVIDER_DERIVED_KEYS = %w[address phone_conflict_comment secondary_phones].freeze
  USER_EDITABLE_KEYS = %w[birth_date gender iin].freeze

  class << self
    def validate!(incoming:, current: {}, allowed_keys: [])
      incoming_attributes = incoming.to_h.deep_stringify_keys
      current_attributes = current.to_h.deep_stringify_keys
      allowed = Array(allowed_keys).map(&:to_s)
      changed_key = incoming_attributes.keys.find do |key|
        managed_key?(key, current_attributes) && allowed.exclude?(key) && current_attributes[key] != incoming_attributes[key]
      end
      return if changed_key.blank?

      raise Crm::Error.new(
        code: 'VALIDATION_ERROR',
        message: "custom_attributes.#{changed_key} is managed by the system",
        status: :unprocessable_content,
        details: { "custom_attributes.#{changed_key}" => ['is managed by the system'] }
      )
    end

    private

    def managed_key?(key, current_attributes)
      return false if USER_EDITABLE_KEYS.include?(key)
      return true if key.start_with?(PREFIX)

      PROVIDER_DERIVED_KEYS.include?(key) && current_attributes['medelement_patient_code'].present?
    end
  end
end
