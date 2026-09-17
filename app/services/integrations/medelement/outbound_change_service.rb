# rubocop:disable Metrics/ClassLength
class Integrations::Medelement::OutboundChangeService
  APPOINTMENT_MOVE_KEYS = %w[starts_at ends_at resource_id].freeze
  APPOINTMENT_SNAPSHOT_KEYS = %w[
    status starts_at ends_at client_phone client_name client_first_name client_last_name client_middle_name
    client_birth_date client_gender client_identifier client_comment service_amount duration_min custom_attributes
    external_ref resource_id service_id service_name_snapshot
  ].freeze
  CONTACT_UPDATE_KEYS = %w[name last_name middle_name email phone_number identifier custom_attributes].freeze
  CONTACT_SNAPSHOT_KEY = 'medelement_contact_snapshot'.freeze
  SPECIALIST_CODE_KEY = 'medelement_specialist_code_snapshot'.freeze
  SPECIALIST_NAME_KEY = 'medelement_specialist_name_snapshot'.freeze
  NOMENCLATURE_CODES_KEY = 'medelement_nomenclature_codes_snapshot'.freeze
  SERVICE_NAME_KEY = 'medelement_service_name_snapshot'.freeze

  class << self
    def contact_event_snapshot(contact)
      return {} if contact.blank?

      contact.attributes.slice(*CONTACT_UPDATE_KEYS)
    end

    def appointment_event_snapshot(appointment)
      appointment.attributes.slice(*APPOINTMENT_SNAPSHOT_KEYS).merge(
        CONTACT_SNAPSHOT_KEY => contact_event_snapshot(appointment.contact),
        SPECIALIST_CODE_KEY => appointment.resource&.custom_attributes.to_h['medelement_specialist_code'],
        SPECIALIST_NAME_KEY => appointment.resource&.name,
        NOMENCLATURE_CODES_KEY => appointment_nomenclature_codes(appointment),
        SERVICE_NAME_KEY => appointment.service_name_snapshot.presence || appointment.service&.name
      )
    end

    private

    def appointment_nomenclature_codes(appointment)
      service_ids = Array(appointment.custom_attributes.to_h['service_ids']).filter_map do |value|
        Integer(value, exception: false)
      end
      service_ids = [appointment.service_id].compact if service_ids.blank?
      services = appointment.account.scheduling_services.where(id: service_ids).index_by(&:id)

      service_ids.filter_map do |service_id|
        services[service_id]&.custom_attributes&.dig('medelement_nomenclature_code').presence
      end.uniq
    end
  end

  # rubocop:disable Metrics/ParameterLists
  def initialize(entity_type:, entity_id:, event_name:, change: {}, account_id: nil, actor_id: nil, actor_descriptor: nil, event_key: nil)
    @account_id = account_id
    @entity_type = entity_type.to_s
    @entity_id = entity_id
    @event_name = event_name.to_s
    @changed_attributes = change.to_h.fetch(:changed_attributes, change.to_h['changed_attributes']).to_h.deep_stringify_keys
    @desired_attributes = change.to_h.fetch(:desired_attributes, change.to_h['desired_attributes']).to_h.deep_stringify_keys
    @actor_id = actor_id
    @actor_descriptor = actor_descriptor
    @event_key = event_key.to_s.presence
  end
  # rubocop:enable Metrics/ParameterLists

  def perform
    case entity_type
    when 'appointment'
      sync_appointment
    when 'contact'
      sync_contact
    else
      raise ArgumentError, "Unsupported Medelement outbound entity: #{entity_type}"
    end
  end

  private

  attr_reader :account, :account_id, :actor_id, :actor_descriptor, :changed_attributes, :desired_attributes, :entity_id, :entity_type, :event_key,
              :event_name, :hook

  def sync_appointment
    appointment = appointment_scope.includes(:account, :contact, :resource, :service).find(entity_id)
    return if appointment.contact.blank?
    return unless provider_resource?(appointment.resource)

    @account = appointment.account
    @hook = writable_hook
    return unless hook

    operation = appointment_operation(appointment)
    return unless operation

    command = create_appointment_command(appointment, operation)
    project_appointment_provider_status!(appointment, command)
    command
  end

  def create_appointment_command(appointment, operation)
    create_and_confirm(
      appointment: appointment,
      contact: appointment.contact,
      operation: operation,
      company_cabinet_code: cabinet_code(appointment),
      desired_starts_at: reception_write?(operation) ? desired_time('starts_at', appointment.starts_at) : nil,
      desired_ends_at: reception_write?(operation) ? desired_time('ends_at', appointment.ends_at) : nil
    )
  end

  def project_appointment_provider_status!(appointment, command)
    command.with_lock do
      provider_status = case command.logical_status
                        when 'succeeded'
                          Integrations::Medelement::AppointmentProviderStatus::SUCCEEDED
                        when 'provider_status_unknown'
                          Integrations::Medelement::AppointmentProviderStatus::UNKNOWN
                        when 'failed', 'declined', 'cancelled'
                          Integrations::Medelement::AppointmentProviderStatus::FAILED
                        else
                          Integrations::Medelement::AppointmentProviderStatus::PENDING
                        end
      Integrations::Medelement::AppointmentProviderStatus.persist!(appointment, provider_status, command: command)
    end
  end

  def sync_contact
    contact = contact_scope.includes(:account).find(entity_id)
    operation = contact_operation(contact)
    return unless operation

    @account = contact.account
    @hook = writable_hook
    return unless hook

    create_and_confirm(
      appointment: nil,
      contact: contact,
      operation: operation,
      company_cabinet_code: nil,
      desired_starts_at: nil,
      desired_ends_at: nil
    )
  end

  def appointment_scope
    return Scheduling::Appointment.all if account_id.blank?

    Scheduling::Appointment.where(account_id: account_id)
  end

  def contact_scope
    return Contact.all if account_id.blank?

    Contact.where(account_id: account_id)
  end

  def appointment_operation(appointment)
    if normalized_event_name == 'appointment_cancelled'
      return 'remove_reception' if cancelled?(appointment) && provider_reception_code(appointment).present?

      return
    end
    return if cancelled?(appointment)
    return 'create_reception' if provider_reception_code(appointment).blank?
    return 'move_reception' if provider_move_changed?
  end

  def contact_operation(contact)
    if normalized_event_name == 'contact_created'
      return 'create_patient' if provider_patient_code(contact).blank?

      return
    end

    return if provider_patient_code(contact).blank?
    return unless changed_attributes.keys.intersect?(CONTACT_UPDATE_KEYS)

    'update_patient'
  end

  def provider_move_changed?
    APPOINTMENT_MOVE_KEYS.any? do |key|
      values = changed_attributes[key]
      values.is_a?(Array) && values.size >= 2 && normalized_move_value(key, values.first) != normalized_move_value(key, values.last)
    end
  end

  def normalized_move_value(key, value)
    return Integer(value, exception: false) if key == 'resource_id'
    return if value.blank?

    Time.zone.parse(value.to_s)&.utc&.iso8601(6)
  rescue ArgumentError
    value.to_s
  end

  # rubocop:disable Metrics/MethodLength, Metrics/ParameterLists
  def create_and_confirm(appointment:, contact:, operation:, company_cabinet_code:, desired_starts_at:, desired_ends_at:)
    command_desired_attributes = snapshot_desired_attributes(operation, appointment)
    command_idempotency_key = idempotency_key(operation, appointment || contact, desired_starts_at, desired_ends_at)
    expected_snapshot = request_snapshot(
      appointment: appointment,
      contact: contact,
      operation: operation,
      company_cabinet_code: company_cabinet_code,
      desired_starts_at: desired_starts_at,
      desired_ends_at: desired_ends_at,
      desired_attributes: command_desired_attributes
    )
    existing = matching_appointment_command(appointment, operation, expected_snapshot)
    return confirm_command(existing) if existing

    command = create_command(
      appointment: appointment,
      contact: contact,
      operation: operation,
      idempotency_key: command_idempotency_key,
      dispatch_identity: event_key,
      company_cabinet_code: company_cabinet_code,
      desired_starts_at: desired_starts_at,
      desired_ends_at: desired_ends_at,
      desired_attributes: command_desired_attributes
    )
    confirm_command(command)
  end
  # rubocop:enable Metrics/MethodLength, Metrics/ParameterLists

  # rubocop:disable Metrics/ParameterLists
  def create_command(appointment:, contact:, operation:, idempotency_key:, dispatch_identity:, company_cabinet_code:,
                     desired_starts_at:, desired_ends_at:, desired_attributes:)
    Integrations::Medelement::ProviderCommands::CreateService.new(
      account: account,
      hook: hook,
      appointment: appointment,
      contact: contact,
      operation: operation,
      idempotency_key: idempotency_key,
      dispatch_identity: dispatch_identity,
      company_cabinet_code: company_cabinet_code,
      actor: actor,
      actor_descriptor: actor_descriptor,
      desired_starts_at: desired_starts_at,
      desired_ends_at: desired_ends_at,
      desired_attributes: desired_attributes
    ).perform
  end
  # rubocop:enable Metrics/ParameterLists

  def writable_hook
    candidate = account.hooks.enabled.find_by(app_id: 'medelement')
    return unless candidate&.feature_allowed?
    return unless Integrations::Medelement::Configuration.new(hook: candidate).write_enabled?

    candidate
  end

  def matching_appointment_command(appointment, operation, expected_snapshot)
    return if appointment.blank?

    existing = Integrations::Medelement::ProviderCommand.where(account: account, appointment: appointment).unfinished.first
    return if existing.blank?
    return existing if existing.operation == operation && same_request_snapshot?(existing.request_snapshot, expected_snapshot)

    raise Scheduling::Error.new(
      code: 'MEDELEMENT_COMMAND_IN_PROGRESS',
      message: 'Another Medelement command is in progress',
      status: :conflict
    )
  end

  def confirm_command(command)
    Integrations::Medelement::ProviderCommands::AutoConfirmationService.new(command: command).perform
  end

  # rubocop:disable Metrics/ParameterLists
  def request_snapshot(appointment:, contact:, operation:, company_cabinet_code:, desired_starts_at:, desired_ends_at:, desired_attributes:)
    Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder.new(
      account: account,
      hook: hook,
      appointment: appointment,
      contact: contact,
      actor: actor,
      actor_descriptor: actor_descriptor,
      operation: operation,
      company_cabinet_code: company_cabinet_code,
      desired_starts_at: desired_starts_at,
      desired_ends_at: desired_ends_at,
      desired_attributes: desired_attributes
    ).build
  end
  # rubocop:enable Metrics/ParameterLists

  def same_request_snapshot?(first, second)
    builder = Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder
    builder.fingerprint(first) == builder.fingerprint(second)
  end

  def idempotency_key(operation, record, desired_starts_at, desired_ends_at)
    if event_key
      digest = Digest::SHA256.hexdigest("#{event_key}:#{operation}")
      return "onelink-outbound:#{entity_type}:#{operation}:#{record.id}:#{digest}"
    end

    intent = {
      event_name: event_name,
      operation: operation,
      entity_type: entity_type,
      entity_id: record.id,
      provider_reference: provider_reference(record),
      desired_starts_at: desired_starts_at&.utc&.iso8601(6),
      desired_ends_at: desired_ends_at&.utc&.iso8601(6),
      changed_attributes: changed_attributes,
      desired_attributes: desired_attributes
    }
    digest = Digest::SHA256.hexdigest(JSON.generate(intent))
    "onelink-outbound:#{entity_type}:#{operation}:#{record.id}:#{digest}"
  end

  def normalized_event_name
    event_name.tr('.', '_')
  end

  def reception_write?(operation)
    operation.in?(%w[create_reception move_reception])
  end

  def serialized_time(value)
    value&.utc&.iso8601(6)
  end

  def provider_reference(record)
    return provider_reception_code(record) if record.is_a?(Scheduling::Appointment)

    provider_patient_code(record)
  end

  def provider_resource?(resource)
    return desired_attributes[SPECIALIST_CODE_KEY].present? if desired_attributes.key?(SPECIALIST_CODE_KEY)

    resource.custom_attributes.to_h['medelement_specialist_code'].present?
  end

  def provider_reception_code(appointment)
    appointment_snapshot_custom_attributes(appointment)['medelement_reception_code'].presence ||
      desired_attributes.fetch('external_ref', appointment.external_ref).to_s.delete_prefix('medelement:reception:').presence
  end

  def provider_patient_code(contact)
    attributes = if entity_type == 'contact'
                   desired_attributes.fetch('custom_attributes', contact.custom_attributes)
                 else
                   desired_attributes.fetch(CONTACT_SNAPSHOT_KEY, {}).fetch('custom_attributes', contact.custom_attributes)
                 end
    attributes.to_h['medelement_patient_code'].presence
  end

  def cabinet_code(appointment)
    appointment_snapshot_custom_attributes(appointment)['medelement_cabinet_code'].to_s.presence
  end

  def cancelled?(appointment)
    desired_attributes.fetch('status', appointment.status).to_s == 'cancelled'
  end

  def desired_time(key, fallback)
    value = desired_attributes[key]
    return fallback if value.blank?
    return value if value.respond_to?(:in_time_zone)

    Time.zone.parse(value.to_s)
  end

  def snapshot_desired_attributes(operation, appointment)
    return desired_attributes unless operation == 'move_reception'

    desired_attributes.merge(
      'medelement_source_starts_at' => changed_source_time('starts_at', appointment.starts_at),
      'medelement_source_ends_at' => changed_source_time('ends_at', appointment.ends_at)
    )
  end

  def changed_source_time(key, fallback)
    value = Array(changed_attributes[key]).first
    return fallback if value.blank?

    value.respond_to?(:in_time_zone) ? value : Time.zone.parse(value.to_s)
  end

  def actor
    @actor ||= account.users.find_by(id: actor_id)
  end

  def appointment_snapshot_custom_attributes(appointment)
    desired_attributes.fetch('custom_attributes', appointment.custom_attributes).to_h
  end
end
# rubocop:enable Metrics/ClassLength
