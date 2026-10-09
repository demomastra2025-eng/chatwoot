class Scheduling::PatientContactCreationService
  REQUESTS_KEY = 'medelement_patient_context_creation_requests'.freeze

  def initialize(account:, contact:, params:)
    @account = account
    @contact = contact
    @params = params.to_h.deep_symbolize_keys
  end

  def perform
    raise ArgumentError, 'Contact must belong to the account' unless contact.account_id == account.id
    raise ArgumentError, 'idempotency_key is required and must be at most 128 characters' if request_key.blank? || request_key.length > 128

    first_name = params[:first_name].to_s.strip.presence || params[:name].to_s.strip.presence
    last_name = params[:last_name].to_s.strip.presence
    raise ArgumentError, 'Patient first and last name are required' if first_name.blank? || last_name.blank?

    if params[:iin].present? && !Scheduling::IinValidator.valid?(params[:iin])
      raise Scheduling::Error.new(code: 'INVALID_IIN', message: 'Invalid IIN', status: :unprocessable_content)
    end
    identifier = Scheduling::IinValidator.normalize(params[:iin].presence || params[:identifier])
    Scheduling::IinValidator.validate!(identifier)
    appointment = account.scheduling_appointments.new(
      contact: contact, conversation: conversation, client_first_name: first_name, client_last_name: last_name,
      client_middle_name: params[:middle_name].to_s.strip.presence,
      client_name: [first_name, last_name, params[:middle_name]].compact_blank.join(' '),
      client_identifier: identifier, client_birth_date: params[:birth_date], client_gender: params[:gender],
      client_phone: params[:phone].presence || params[:phone_number].presence || contact.phone_number,
      custom_attributes: { Integrations::Medelement::AppointmentPatientIdentity::OWNED_IDENTITY_KEY => true }
    )
    ApplicationRecord.transaction do
      Contacts::PhoneIdentityLock.acquire!(account_id: account.id)
      fingerprint = creation_fingerprint(appointment)
      existing = account.contacts.find_by("custom_attributes -> '#{REQUESTS_KEY}' ? :key", key: request_key)
      if existing
        validate_duplicate!(existing, fingerprint)
        existing
      else
        card = Integrations::Medelement::PatientContactBinding.new(appointment: appointment).prepare!
        record_context!(card, fingerprint)
        card
      end
    end
  end

  private

  attr_reader :account, :contact, :params

  def request_key = params[:idempotency_key].to_s.strip

  def creation_fingerprint(appointment)
    fields = Integrations::Medelement::AppointmentPatientIdentity::FIELDS
    intent = fields.index_with { |key| appointment.public_send(key).as_json }.merge(
      'contact_id' => contact.id, 'conversation_id' => appointment.conversation_id
    )
    Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder.fingerprint(intent)
  end

  def validate_duplicate!(card, fingerprint)
    return if card.custom_attributes.to_h.dig(REQUESTS_KEY, request_key) == fingerprint

    raise Scheduling::Error.new(code: 'PATIENT_IDEMPOTENCY_KEY_REUSED', message: 'The patient creation key was already used for different details',
                                status: :conflict)
  end

  def record_context!(card, fingerprint)
    attributes = card.custom_attributes.to_h
    key = Scheduling::PatientContextQuery::CONTACT_IDS_KEY
    attributes[key] = (Array(attributes[key]) + [contact.id]).uniq
    attributes[REQUESTS_KEY] = attributes[REQUESTS_KEY].to_h.merge(request_key => fingerprint)
    card.skip_runtime_events = true
    card.update!(custom_attributes: attributes)
  end

  def conversation
    value = if params[:conversation_id].present?
              account.conversations.find(params[:conversation_id])
            elsif params[:conversation_display_id].present?
              account.conversations.find_by!(display_id: params[:conversation_display_id])
            end
    raise ArgumentError, 'Conversation must belong to the communication contact' if value && value.contact_id != contact.id

    value
  end
end
