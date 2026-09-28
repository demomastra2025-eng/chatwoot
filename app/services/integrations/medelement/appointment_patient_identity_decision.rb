class Integrations::Medelement::AppointmentPatientIdentityDecision
  attr_reader :explicit, :owned, :transition

  def initialize(appointment:, contact:, params:, identity:, mapped:)
    @appointment = appointment
    @contact = contact
    @params = params
    @identity = identity
    @mapped = mapped
    @explicit = policy.explicit_identifier?(appointment.custom_attributes) || (mapped && params.key?(:client_identifier))
    @owned = policy.owned?(appointment.custom_attributes)
    @transition = false
  end

  def resolve!
    return self unless identity

    ensure_linked_identity_unchanged! if owned && provider_linked?
    resolve_authored_identity! if authored_identity_requires_resolution?
    self
  end

  private

  attr_reader :appointment, :contact, :params, :identity, :mapped

  def policy
    Integrations::Medelement::AppointmentPatientIdentity
  end

  def authored_identity?
    params.key?(:client_identifier) || policy::NAME_KEYS.any? { |key| params.key?("client_#{key}".to_sym) }
  end

  def authored_identity_requires_resolution?
    mapped && authored_identity? && (explicit || appointment.new_record?)
  end

  def identifier
    Scheduling::IinValidator.normalize(params[:client_identifier]) if params.key?(:client_identifier)
  end

  def resolve_authored_identity!
    names_match = policy.names_match?(identity, contact)
    contact_identifier = policy.contact_iin(contact)
    identity_conflict! if known_identifier_conflict?(contact_identifier, names_match)

    separate = !names_match || identifier_differs?(contact_identifier)
    @transition = separate && !owned
    @owned ||= separate
    ensure_linked_identity_unchanged! if provider_linked?
  end

  def known_identifier_conflict?(contact_identifier, names_match)
    identifier.present? && identifier == contact_identifier && !names_match
  end

  def identifier_differs?(contact_identifier)
    identifier.present? && identifier != contact_identifier
  end

  def provider_linked?
    appointment.external_ref.to_s.start_with?('medelement:reception:') ||
      appointment.custom_attributes.to_h['medelement_reception_code'].present? ||
      appointment.custom_attributes.to_h['medelement_patient_code'].present?
  end

  def ensure_linked_identity_unchanged!
    identity_conflict! if transition || name_changed? || identifier_changed?
  end

  def name_changed?
    policy::NAME_KEYS.any? do |key|
      field = "client_#{key}"
      policy.normalize(field, appointment.public_send(field)) != policy.normalize(field, identity[key.to_sym])
    end
  end

  def identifier_changed?
    params.key?(:client_identifier) && Scheduling::IinValidator.normalize(appointment.client_identifier) != identifier
  end

  def identity_conflict!
    raise Scheduling::Error.new(
      code: 'MEDELEMENT_PATIENT_IDENTITY_CONFLICT',
      message: 'Select a separate patient or create a new appointment before changing the linked patient identity',
      status: :conflict
    )
  end
end
