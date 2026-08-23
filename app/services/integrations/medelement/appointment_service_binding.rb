class Integrations::Medelement::AppointmentServiceBinding
  BINDING_KEY = 'medelement_service_binding'.freeze
  LOCAL_CODES_KEY = 'medelement_local_nomenclature_codes'.freeze
  PROVIDER_CODES_KEY = 'medelement_provider_nomenclature_codes'.freeze
  LOCAL_ONLY = 'local_only'.freeze
  PROVIDER = 'provider'.freeze
  ATTRIBUTE_KEYS = [BINDING_KEY, LOCAL_CODES_KEY, PROVIDER_CODES_KEY].freeze

  def initialize(appointment:)
    @appointment = appointment
  end

  def local_only?
    appointment.custom_attributes.to_h[BINDING_KEY] == LOCAL_ONLY
  end

  def preserve_local_selection?(reception)
    local_only? && explicit_empty_provider_services?(reception)
  end

  def provider_identity_authoritative?(reception)
    Integrations::Medelement::ReceptionServiceRows.identity_authoritative?(reception) &&
      !preserve_local_selection?(reception)
  end

  def local_only_attributes(nomenclature_codes)
    {
      BINDING_KEY => LOCAL_ONLY,
      LOCAL_CODES_KEY => normalized_codes(nomenclature_codes),
      PROVIDER_CODES_KEY => []
    }
  end

  def provider_attributes(nomenclature_codes)
    {
      BINDING_KEY => PROVIDER,
      PROVIDER_CODES_KEY => normalized_codes(nomenclature_codes)
    }
  end

  def observed_provider_attributes(nomenclature_codes)
    { PROVIDER_CODES_KEY => normalized_codes(nomenclature_codes) }
  end

  def reconcile_provider_attributes(attributes:, reception:, services:, unresolved_service_codes:)
    return attributes unless Integrations::Medelement::ReceptionServiceRows.identity_authoritative?(reception)
    return attributes.merge(observed_provider_attributes([])) if preserve_local_selection?(reception)

    provider_codes = services.map { |service| service.custom_attributes['medelement_nomenclature_code'] }
    provider_codes.concat(unresolved_service_codes)
    attributes.except(LOCAL_CODES_KEY).merge(
      'service_ids' => services.map(&:id),
      'services' => services.map { |service| service.slice(:id, :name, :service_type, :duration_min) },
      'medelement_unresolved_service_codes' => unresolved_service_codes
    ).merge(provider_attributes(provider_codes))
  end

  private

  attr_reader :appointment

  def explicit_empty_provider_services?(reception)
    reception['SERVICES'].is_a?(Array) && reception['SERVICES'].empty?
  end

  def normalized_codes(codes)
    Array(codes).filter_map { |code| code.to_s.presence }.uniq
  end
end
