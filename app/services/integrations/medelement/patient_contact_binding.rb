class Integrations::Medelement::PatientContactBinding
  CARD_KEY = Contacts::SharedPhone::CARD_KEY
  SHARED_OWNER_KEY = Contacts::SharedPhone::SHARED_OWNER_KEY
  SHARED_PHONE_KEY = Contacts::SharedPhone::SHARED_PHONE_KEY
  STAFF_OWNER_KEY = 'medelement_patient_context_staff_selected_owner'.freeze

  def initialize(appointment:)
    @appointment = appointment
  end

  def prepare!(patient_code: nil, allow_rebind: false)
    return unless policy.owned?(appointment.custom_attributes)

    Contacts::PhoneIdentityLock.acquire!(account_id: appointment.account_id)
    return unless adoptable?(patient_code)

    code = patient_code.to_s.presence || appointment_patient_code
    contact = resolve_contact(code, allow_rebind)
    validate_contact!(contact, code)
    code ||= code_for(contact)
    placeholder = release_replaced_placeholder!(contact)
    persist_contact!(contact, code, placeholder: placeholder) unless established_communication_patient?(contact)
    appointment.patient_contact = contact
    appointment.custom_attributes = appointment.custom_attributes.to_h.merge('medelement_patient_code' => code) if code
    contact
  end

  # Only the authenticated, explicitly selected card uses this path. Automatic imports and callbacks
  # keep prepare!'s reference/IIN lookup rules. The caller fences existing provider writes first.
  def prepare_selected!(contact:, allow_communication_contact: false)
    Contacts::PhoneIdentityLock.acquire!(account_id: appointment.account_id)
    code = code_for(contact)
    validate_learned_code!(code)
    validate_contact!(contact, code, allow_communication_contact: allow_communication_contact)
    placeholder = release_replaced_placeholder!(contact)
    # A verified existing patient may also own the chat. Staff admission binds the appointment;
    # it never changes that communication contact's profile, number, share or clinical history.
    persist_contact!(contact, code, placeholder: placeholder) unless allow_communication_contact && contact.id == appointment.contact_id
    appointment.patient_contact = contact
    if allow_communication_contact && contact.id == appointment.contact_id
      appointment.custom_attributes = appointment.custom_attributes.to_h.merge(STAFF_OWNER_KEY => true)
    end
    appointment.custom_attributes = appointment.custom_attributes.to_h.merge('medelement_patient_code' => code) if code
    contact
  end

  def self.legacy_owner_holds_code?(appointment)
    code = appointment.custom_attributes.to_h['medelement_patient_code'].to_s.presence
    return false if code.nil? || appointment.patient_contact_id.present? || appointment.contact.nil?

    appointment.contact.custom_attributes.to_h['medelement_patient_code'].to_s == code
  end

  # The communication contact of an imported appointment of this card (see Contacts::SharedPhone.route_contact).
  def self.delivery_contact(patient)
    Contacts::SharedPhone.route_contact(patient)
  end

  def self.provider_phone(appointment, authored_phone:)
    card = appointment.patient_contact
    if card && card.account_id != appointment.account_id
      raise Scheduling::Error.new(code: 'MEDELEMENT_PATIENT_IDENTITY_CONFLICT', message: 'Patient card belongs to another account', status: :conflict)
    end

    phone = Integrations::Medelement::PhoneNumber.normalize(card&.phone_number.presence || authored_phone)
    return phone if phone

    raise Scheduling::Error.new(code: 'MEDELEMENT_PATIENT_PHONE_INVALID', message: 'Patient phone must be a valid Kazakhstan number',
                                status: :conflict)
  end

  def self.recorded_contact_by_iin(account:, iin:)
    identifier = Scheduling::IinValidator.normalize(iin)
    return unless Scheduling::IinValidator.valid?(identifier)

    candidates = account.contacts.where(
      "identifier = :iin OR custom_attributes ->> 'iin' = :iin OR custom_attributes ->> 'medelement_iin' = :iin", iin: identifier
    ).order(:id).to_a.select { |contact| Contacts::SharedPhone.recorded_patient_identity?(contact, identifier) }
    if candidates.many?
      raise Scheduling::Error.new(code: 'MEDELEMENT_PATIENT_IDENTITY_CONFLICT', message: 'Patient identity has several local cards', status: :conflict)
    end
    candidates.first
  end

  private

  attr_reader :appointment

  def policy = Integrations::Medelement::AppointmentPatientIdentity

  def code_for(contact) = contact.custom_attributes.to_h['medelement_patient_code'].to_s.presence

  def identifier = Scheduling::IinValidator.normalize(appointment.client_identifier)

  def appointment_patient_code = appointment.custom_attributes.to_h['medelement_patient_code'].to_s.presence

  def adoptable?(patient_code)
    validate_learned_code!(patient_code)
    # Pre-release data: the chat contact already holds this appointment's patient code. Keep the unbound
    # behaviour until the explicit repair task separates the card; never adopt the chat contact as the patient.
    !self.class.legacy_owner_holds_code?(appointment)
  end

  # Imports and provider callbacks may confirm the recorded patient reference, never re-point the appointment.
  def validate_learned_code!(patient_code)
    learned = patient_code.to_s.presence
    return unless learned

    recorded = [appointment_patient_code, appointment.patient_contact && code_for(appointment.patient_contact)].compact
    identity_conflict!('The provider reference belongs to another patient') if recorded.any? { |code| code != learned }
  end

  def resolve_contact(code, allow_rebind)
    bound = appointment.patient_contact
    confirmed = confirmed_contact(code)
    return confirmed || appointment.account.contacts.new unless bound
    return draft_contact(bound, confirmed) if allow_rebind && replaceable_placeholder?(bound)
    return bound if confirmed.nil? || bound.id == confirmed.id

    identity_conflict!('The patient already has another local card')
  end

  def draft_contact(bound, confirmed)
    return confirmed || appointment.account.contacts.new if authored_identifier_changed?(bound)

    confirmed || bound
  end

  def confirmed_contact(code)
    coded = appointment.account.contacts.find_by("custom_attributes ->> 'medelement_patient_code' = ?", code) if code
    identified = contact_by_iin
    identity_conflict!('The IIN and provider reference identify different cards') if coded && identified && coded.id != identified.id
    coded || identified
  end

  def replaceable_placeholder?(contact)
    code_for(contact).blank? && contact.custom_attributes.to_h[CARD_KEY] == true &&
      policy.contact_iin(contact) == Scheduling::IinValidator.normalize(appointment.attribute_in_database('client_identifier')) &&
      !contact.patient_scheduling_appointments.where.not(id: appointment.id).exists?
  end

  def authored_identifier_changed?(contact)
    policy.contact_iin(contact) != identifier
  end

  # Only server-recorded patient identities are resolved by IIN: a card created by this binding (CARD_KEY), a MedElement
  # patient (code) or a contact whose medelement_iin the provider wrote. An identifier or custom 'iin' alone may have
  # been self-declared by a widget visitor or public API client (no HMAC): such a contact never decides the patient and
  # never turns a booking into "several local cards" or a name-mismatch conflict.
  def contact_by_iin
    self.class.recorded_contact_by_iin(account: appointment.account, iin: identifier)
  end

  def validate_contact!(contact, code, allow_communication_contact: false)
    validate_authored_name!(contact)
    return unless contact.account_id
    forbidden_owner = unbound_communication_owner?(contact) && !allow_communication_contact
    return unless contact.account_id != appointment.account_id || forbidden_owner ||
                  different_known_value?(code_for(contact), code) || different_known_value?(policy.contact_iin(contact), identifier)

    identity_conflict!('The patient card belongs to another patient')
  end

  def unbound_communication_owner?(contact)
    contact.id == appointment.contact_id && contact.id != appointment.patient_contact_id
  end

  def established_communication_patient?(contact)
    contact.id == appointment.contact_id && contact.id == appointment.patient_contact_id &&
      appointment.custom_attributes.to_h[STAFF_OWNER_KEY] == true && code_for(contact).present? &&
      Scheduling::IinValidator.valid?(contact.custom_attributes.to_h['medelement_iin']) &&
      Scheduling::IinValidator.normalize(contact.custom_attributes.to_h['medelement_iin']) == identifier
  end

  def different_known_value?(stored, desired)
    stored.present? && desired.present? && stored != desired
  end

  def validate_authored_name!(contact)
    return if contact.id.blank? || contact.id == appointment.patient_contact_id
    return if policy.contact_iin(contact).blank? || policy.contact_iin(contact) != identifier

    identity = policy::NAME_KEYS.index_with { |key| appointment.public_send("client_#{key}") }.symbolize_keys
    identity_conflict!('The patient card name does not match the authored identity') unless policy.names_match?(identity, contact)
  end

  def persist_contact!(contact, code, placeholder: nil)
    attributes = contact.custom_attributes.to_h.merge(CARD_KEY => true)
    attributes['medelement_patient_code'] = code if code
    attributes['iin'] = appointment.client_identifier if appointment.client_identifier.present?
    contact.skip_runtime_events = true
    assign_authored_identity!(contact, code, attributes)
    assign_patient_phone!(contact, attributes, placeholder: placeholder)
    contact.custom_attributes = attributes.compact
    contact.save! if contact.new_record? || contact.changed?
  end

  # A draft card replaced on rebind keeps its identity but releases the booking number (PatientPlaceholderRelease).
  def release_replaced_placeholder!(contact)
    bound = appointment.patient_contact
    return unless bound&.persisted? && bound.id != contact.id
    return unless replaceable_placeholder?(bound)

    Integrations::Medelement::PatientPlaceholderRelease.new(placeholder: bound, phone: booking_phone).perform
  end

  def booking_phone = Integrations::Medelement::PhoneNumber.normalize(appointment.client_phone)

  def assign_authored_identity!(contact, code, attributes)
    return unless contact.new_record? || (contact.id == appointment.patient_contact_id && code.blank?)

    contact.account = appointment.account
    contact.assign_attributes(authored_contact_attributes(contact))
    attributes['birth_date'] = appointment.client_birth_date&.iso8601
    attributes['gender'] = appointment.client_gender
  end

  # The card keeps the IIN in custom_attributes['iin'] in any case; the unique contact identifier is left alone when an
  # unrecorded (self-declared) contact already carries the same value.
  def authored_contact_attributes(contact)
    attributes = { name: appointment.client_first_name.presence || appointment.client_name,
                   last_name: appointment.client_last_name, middle_name: appointment.client_middle_name }
    identifier_taken = appointment.client_identifier.present? &&
                       appointment.account.contacts.where(identifier: appointment.client_identifier).where.not(id: contact.id).exists?
    attributes[:identifier] = appointment.client_identifier unless identifier_taken
    attributes
  end

  # M1/M2: the booking number becomes the card's own primary only when nobody holds it, nobody chats from it, it is not
  # reserved for another hidden share, and the booking chat itself showed a phone. Otherwise the card gets it as a доп.
  # номер with the recorded share (owner, via, booking chat); the card never takes the family number from the chat.
  # The card's own recorded доп. номер stays one even after its holder released it: it becomes the card's primary only
  # through Contacts::SharedPhonePromotionService (behind Contacts::SharedPhoneSwitches), never on a booking, an
  # appointment update, a MedElement import or a provider write-back (same rule as ContactResolverService).
  def assign_patient_phone!(contact, attributes, placeholder: nil)
    phone = booking_phone
    return remove_shared_phone!(contact, attributes, phone) if contact.phone_number.present?
    return if phone.blank?

    share = patient_phone_share(contact, phone, excluding: [contact.id, placeholder&.id])
    return Contacts::SharedPhone.record_share!(attributes, phone: phone, **share) if share
    return if own_shared_phone?(contact, phone)
    return unless Contacts::SharedPhone.assignable_primary?(account_id: appointment.account_id, phone: phone, contact_id: contact.id)

    contact.phone_number = phone
    remove_shared_phone!(contact, attributes, phone)
  end

  def own_shared_phone?(contact, phone) = Contacts::SharedPhone.share_of(contact)&.phone == phone

  def patient_phone_share(contact, phone, excluding:)
    existing = Contacts::SharedPhone.existing_share_for(account_id: appointment.account_id, phone: phone, excluding: excluding,
                                                        preferred_owner_id: appointment.contact_id)
    return existing.merge(conversation_id: existing[:conversation_id] || booking_conversation_id_for(existing[:owner_id])) if existing
    return unless hidden_booking_owner?(contact)

    { owner_id: appointment.contact_id, via: Contacts::SharedPhone::VIA_BOOKING_CHAT, conversation_id: appointment.conversation_id }
  end

  # The booking chat did not show its phone (WhatsApp Web LID-only, Telegram Personal, widget, social): the number was
  # given by the person writing, so it is shared from that chat and reserved for its contact until the chat reveals it.
  def hidden_booking_owner?(contact)
    owner = appointment.contact
    owner.present? && owner.persisted? && owner.id != contact.id && owner.phone_number.blank?
  end

  def booking_conversation_id_for(owner_id)
    appointment.conversation_id if owner_id.present? && appointment.conversation&.contact_id == owner_id
  end

  def remove_shared_phone!(contact, attributes, phone)
    owner = appointment.account.contacts.find_by(id: attributes[SHARED_OWNER_KEY])
    recorded = attributes[SHARED_PHONE_KEY]
    Contacts::SharedPhone.clear_share!(attributes)
    holder = Contacts::SharedPhone.primary_holder(account_id: appointment.account_id, phone: phone, excluding: [contact.id])
    attributes['secondary_phones'] = Array(attributes['secondary_phones']) -
                                     [owner&.phone_number, contact.phone_number, holder&.phone_number, recorded].compact
  end

  def identity_conflict!(message)
    raise Scheduling::Error.new(code: 'MEDELEMENT_PATIENT_IDENTITY_CONFLICT', message: message, status: :conflict)
  end
end
