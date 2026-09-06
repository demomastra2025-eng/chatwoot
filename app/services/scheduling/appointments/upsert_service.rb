class Scheduling::Appointments::UpsertService
  APPOINTMENT_BOOKING_INTAKE_CONTEXT = 'booking_intake'.freeze
  CLIENT_NAME_PART_KEYS = %i[client_first_name client_last_name client_middle_name].freeze
  DERIVED_SYSTEM_CUSTOM_ATTRIBUTE_KEYS = %w[service_ids services].freeze
  INTAKE_SYSTEM_CUSTOM_ATTRIBUTE_KEYS = %w[medelement_cabinet_code].freeze
  PRESERVED_SYSTEM_CUSTOM_ATTRIBUTE_KEYS = %w[source_mode].freeze
  PRESERVED_SYSTEM_CUSTOM_ATTRIBUTE_PREFIXES = %w[medelement_].freeze

  def initialize(account:, params:, appointment: nil, actor: nil)
    @account = account
    @params = params.to_h.deep_symbolize_keys
    @appointment = appointment || account.scheduling_appointments.new
    @actor = actor
  end

  def perform
    Scheduling::Appointments::MutationGuard.ensure_editable!(appointment)
    Scheduling::Appointments::MutationGuard.ensure_assignable!(params)

    with_actor_context { persist_appointment! }

    appointment.reload
    @provider_receipt_service&.perform
    appointment
  end

  private

  attr_reader :account, :actor, :appointment, :params

  def user_actor
    actor if actor.is_a?(User)
  end

  def with_actor_context
    previous_actor = Current.executed_by
    Current.executed_by = actor if actor.present?
    yield
  ensure
    Current.executed_by = previous_actor
  end

  def persist_appointment!
    ApplicationRecord.transaction do
      apply_attributes!
      mark_medelement_provider_confirmation_pending!
      validate_medelement_patient!
      validate_medelement_cabinet!
      validate_availability!
      new_record = appointment.new_record?
      appointment.save!
      capture_provider_receipt_service!(new_record)
      notify_assignment!(new_record: new_record)
      auto_apply_default_touch_plan! if new_record
      sync_or_cancel_related_touches!
      Scheduling::Appointments::FinanceSyncService.new(appointment: appointment, actor: user_actor).sync!
    end
  end

  def capture_provider_receipt_service!(new_record)
    @provider_receipt_service = Integrations::Medelement::AppointmentProviderCommandReceiptService.new(
      appointment: appointment,
      actor: actor,
      new_record: new_record
    )
  end

  def apply_attributes!
    resource = resolve_resource!
    contact = resolve_optional_record(:contact_id, account.contacts, current: appointment.contact)
    ensure_contact_present!(contact)
    services = resolve_services(current: current_services)
    primary_service = services.first
    company = resolve_company(contact)
    conversation = resolve_conversation
    ensure_conversation_belongs_to_contact!(conversation, contact)
    created_by = resolve_optional_record(:created_by_id, account.users, current: appointment.created_by || user_actor)
    owner = resolve_owner(contact: contact, resource: resource)

    starts_at = resolve_datetime(:starts_at, current: appointment.starts_at)
    duration_min = resolve_duration_min(
      starts_at: starts_at,
      resource: resource,
      services: services,
      current_duration_min: appointment.duration_min
    )
    ends_at = resolve_ends_at(starts_at: starts_at, duration_min: duration_min, current: appointment.ends_at)

    service_snapshot = resolve_service_snapshot(resource: resource, services: services)
    service_amount = resolve_service_amount(
      resource: resource,
      services: services,
      resolved_price: service_snapshot[:resolved_price]
    )
    prepaid_amount = resolve_int(:prepaid_amount, current: appointment.prepaid_amount || 0)
    prepaid_payment_method = resolve_prepaid_payment_method(prepaid_amount)
    settlement_amount = resolve_int(:settlement_amount, current: appointment.settlement_amount || 0)
    client_identity = resolve_client_identity(contact, resource)

    requested_payment_status = resolve_string(:payment_status, current: appointment.payment_status.presence || 'awaiting_payment')
    requested_payment_status = 'cancelled' if resolve_string(:status, current: appointment.status.presence || 'scheduled') == 'cancelled' &&
                                              !params.key?(:payment_status)

    appointment.assign_attributes(
      account: account,
      resource: resource,
      contact: contact,
      service: primary_service,
      company: company,
      conversation: conversation,
      created_by: created_by,
      owner: owner,
      starts_at: starts_at,
      ends_at: ends_at,
      duration_min: duration_min,
      status: resolve_string(:status, current: appointment.status.presence || 'scheduled'),
      appointment_type: resolve_string(:appointment_type, current: appointment.appointment_type.presence || 'primary'),
      client_first_name: client_identity&.fetch(:first_name, nil),
      client_last_name: client_identity&.fetch(:last_name, nil),
      client_middle_name: client_identity&.fetch(:middle_name, nil),
      client_name: client_identity ? client_identity.values.compact_blank.join(' ') : resolve_client_name(contact),
      client_phone: resolve_client_phone(contact),
      client_identifier: resolve_client_identifier(contact),
      client_birth_date: resolve_client_birth_date(contact),
      client_gender: resolve_client_gender(contact),
      client_comment: resolve_optional_text(:client_comment, current: appointment.client_comment),
      source: appointment.source.presence || 'manual',
      external_ref: resolve_optional_text(:external_ref, current: appointment.external_ref),
      idempotency_key: resolve_optional_text(:idempotency_key, current: appointment.idempotency_key),
      service_name_snapshot: service_snapshot[:service_name_snapshot],
      service_type_snapshot: service_snapshot[:service_type_snapshot],
      service_duration_min_snapshot: service_snapshot[:service_duration_min_snapshot],
      service_amount: service_amount,
      compensation_type_snapshot: service_snapshot[:compensation_type_snapshot],
      compensation_value_snapshot: service_snapshot[:compensation_value_snapshot],
      compensation_percent_snapshot: service_snapshot[:compensation_percent_snapshot],
      prepaid_amount: prepaid_amount,
      prepaid_payment_method: prepaid_payment_method,
      settlement_amount: settlement_amount,
      settlement_payment_method: resolve_optional_text(:settlement_payment_method, current: appointment.settlement_payment_method),
      payment_status: derive_payment_status(
        service_amount: service_amount,
        prepaid_amount: prepaid_amount,
        settlement_amount: settlement_amount,
        requested_status: requested_payment_status
      ),
      custom_attributes: resolve_custom_attributes(resource: resource, services: services)
    )
  end

  def resolve_prepaid_payment_method(prepaid_amount)
    return nil if prepaid_amount.to_i <= 0

    resolve_optional_text(:prepaid_payment_method, current: appointment.prepaid_payment_method) ||
      resolve_optional_text(:settlement_payment_method, current: appointment.settlement_payment_method) ||
      'cash'
  end

  def availability_service
    Scheduling::AvailabilityService.new(
      resource: appointment.resource,
      from: appointment.starts_at.beginning_of_day - 1.day,
      to: appointment.ends_at.end_of_day + 1.day,
      holidays: account.scheduling_holidays.ordered.to_a,
      workday_overrides: appointment.resource.workday_overrides.where(date: (appointment.starts_at.to_date - 2)..(appointment.ends_at.to_date + 2)).to_a,
      time_offs: account.scheduling_time_offs
                        .where(resource_id: [nil, appointment.resource_id])
                        .where('starts_at < ? AND ends_at > ?', appointment.ends_at, appointment.starts_at)
                        .to_a,
      appointments: account.scheduling_appointments
                           .where(resource_id: appointment.resource_id)
                           .where('starts_at < ? AND ends_at > ?', appointment.ends_at, appointment.starts_at)
                           .to_a,
      ignore_appointment_id: appointment.id
    )
  end

  def derive_payment_status(service_amount:, prepaid_amount:, settlement_amount:, requested_status:)
    return 'cancelled' if requested_status == 'cancelled'

    total_received = prepaid_amount.to_i + settlement_amount.to_i
    return 'awaiting_payment' if total_received <= 0
    return 'paid' if service_amount.to_i <= 0 || total_received >= service_amount.to_i

    'prepaid'
  end

  def resolve_client_birth_date(contact)
    return resolve_date(:client_birth_date, current: appointment.client_birth_date) if params.key?(:client_birth_date)

    current_value = appointment.client_birth_date || contact&.custom_attributes&.dig('birth_date')
    current_value.is_a?(String) ? Date.iso8601(current_value) : current_value
  rescue Date::Error
    nil
  end

  def resolve_client_gender(contact)
    resolve_optional_text(:client_gender, current: appointment.client_gender || contact&.custom_attributes&.dig('gender'))
  end

  def resolve_client_identifier(contact)
    identifier = resolve_optional_text(
      :client_identifier,
      current: appointment.client_identifier || contact&.identifier || contact&.custom_attributes&.dig('iin')
    )

    Scheduling::IinValidator.validate!(identifier)
  end

  def resolve_client_name(contact)
    resolved = resolve_optional_text(
      :client_name,
      current: appointment.client_name.presence || contact&.name || contact&.email || contact&.phone_number
    )

    return resolved if resolved.present?

    raise ArgumentError, 'client_name is required'
  end

  def resolve_client_identity(contact, resource)
    return unless structured_client_identity?(contact, resource)

    contact_identity = contact_identity_fallback(contact, resource)

    identity = {
      first_name: resolve_client_name_part(:client_first_name, contact_identity[:first_name]),
      last_name: resolve_client_name_part(:client_last_name, contact_identity[:last_name]),
      middle_name: resolve_client_name_part(:client_middle_name, contact_identity[:middle_name])
    }
    return identity if identity[:first_name].present? || medelement_resource?(resource)

    raise ArgumentError, 'client_first_name is required'
  end

  def structured_client_identity?(contact, resource)
    CLIENT_NAME_PART_KEYS.any? { |key| params.key?(key) } ||
      CLIENT_NAME_PART_KEYS.any? { |key| appointment.public_send(key).present? } ||
      (medelement_resource?(resource) && medelement_contact_identity_present?(contact))
  end

  def medelement_contact_identity_present?(contact)
    medelement_contact_name_present?(contact) || (contact&.name.present? && contact&.last_name.present?)
  end

  def medelement_contact_name_present?(contact)
    %w[medelement_first_name medelement_last_name medelement_middle_name].any? do |key|
      contact&.custom_attributes.to_h[key].present?
    end
  end

  def contact_identity_fallback(contact, resource)
    return medelement_contact_identity(contact) if medelement_resource?(resource) && medelement_contact_name_present?(contact)

    { first_name: contact&.name, last_name: contact&.last_name, middle_name: contact&.middle_name }
  end

  def medelement_contact_identity(contact)
    attributes = contact&.custom_attributes.to_h
    {
      first_name: attributes['medelement_first_name'].presence,
      last_name: attributes['medelement_last_name'].presence,
      middle_name: attributes['medelement_middle_name'].presence
    }
  end

  def resolve_client_name_part(param_key, fallback)
    current = appointment.public_send(param_key).presence || fallback
    resolve_optional_text(param_key, current: current)
  end

  def resolve_client_phone(contact)
    resolve_optional_text(:client_phone, current: appointment.client_phone || contact&.phone_number)
  end

  def validate_medelement_patient!
    return unless medelement_resource?
    return if appointment.status == 'cancelled'

    if appointment.client_first_name.blank? || appointment.client_last_name.blank?
      raise Scheduling::Error.new(
        code: 'MEDELEMENT_PATIENT_NAME_INCOMPLETE',
        message: 'Patient first and last name are required for Medelement',
        status: :unprocessable_content
      )
    end

    validate_medelement_phone!
    validate_medelement_services!
  end

  def validate_medelement_cabinet!
    return unless medelement_resource?
    return if appointment.status == 'cancelled'
    return unless medelement_cabinet_validation_required?

    cabinet_code = appointment.custom_attributes.to_h['medelement_cabinet_code'].to_s.presence
    if cabinet_code.blank?
      raise Scheduling::Error.new(
        code: 'MEDELEMENT_CABINET_REQUIRED',
        message: 'Medelement cabinet must be selected',
        status: :unprocessable_content
      )
    end

    valid_codes = Array(appointment.resource.custom_attributes.to_h['medelement_cabinets']).pluck('companyCabinetCode').map(&:to_s)
    return if cabinet_code.in?(valid_codes)

    raise Scheduling::Error.new(
      code: 'MEDELEMENT_CABINET_INVALID',
      message: 'Medelement cabinet must belong to the selected specialist',
      status: :unprocessable_content
    )
  end

  def medelement_cabinet_validation_required?
    appointment.new_record? || params.key?(:resource_id) || params[:custom_attributes].to_h.with_indifferent_access.key?(:medelement_cabinet_code)
  end

  def validate_medelement_phone!
    return if Integrations::Medelement::PhoneNumber.normalize(appointment.client_phone).present?

    raise Scheduling::Error.new(
      code: 'MEDELEMENT_PATIENT_PHONE_INVALID',
      message: 'A Kazakhstan phone number is required for Medelement',
      status: :unprocessable_content
    )
  end

  def validate_medelement_services!
    service_ids = medelement_service_ids
    return if service_ids.empty?

    services = account.scheduling_services.where(id: service_ids)

    validate_medelement_service_mapping!(services, service_ids)
    validate_medelement_service_availability!(service_ids)
  end

  def medelement_service_ids
    custom_service_ids = Array(appointment.custom_attributes.to_h['service_ids']).presence
    (custom_service_ids || Array(appointment.service_id)).compact.uniq
  end

  def validate_medelement_service_mapping!(services, service_ids)
    all_mapped = services.size == service_ids.size && services.all? do |service|
      service.custom_attributes.to_h['medelement_nomenclature_code'].present?
    end
    return if all_mapped

    raise Scheduling::Error.new(
      code: 'MEDELEMENT_SERVICE_UNMAPPED',
      message: 'Selected services must be linked to Medelement',
      status: :unprocessable_content
    )
  end

  def validate_medelement_service_availability!(service_ids)
    linked_service_ids = account.scheduling_service_prices.active
                                .where(resource_id: appointment.resource_id)
                                .joins(:service)
                                .where("NULLIF(scheduling_services.custom_attributes ->> 'medelement_nomenclature_code', '') IS NOT NULL")
                                .pluck(:service_id)
    return if linked_service_ids.empty?
    return if (service_ids - linked_service_ids).empty?

    raise Scheduling::Error.new(
      code: 'MEDELEMENT_SERVICE_UNAVAILABLE',
      message: 'Selected services are not linked to this Medelement specialist',
      status: :unprocessable_content
    )
  end

  def medelement_resource?(resource = appointment.resource)
    resource&.custom_attributes.to_h['medelement_specialist_code'].present?
  end

  def mark_medelement_provider_confirmation_pending!
    return unless medelement_provider_write_required?

    Integrations::Medelement::AppointmentProviderStatus.assign_pending!(appointment)
  end

  def medelement_provider_write_required?
    return false unless medelement_provider_write_context?
    return appointment.status != 'cancelled' if appointment.new_record?

    medelement_existing_appointment_write_required?
  end

  def medelement_provider_write_context?
    medelement_resource? && medelement_outbound_actor? && writable_medelement_hook?
  end

  def medelement_existing_appointment_write_required?
    return appointment.status != 'cancelled' if medelement_reception_code.blank?
    return appointment.will_save_change_to_status? if appointment.status == 'cancelled'

    appointment.will_save_change_to_starts_at? || appointment.will_save_change_to_ends_at?
  end

  def medelement_reception_code
    appointment.custom_attributes.to_h['medelement_reception_code'].presence ||
      appointment.external_ref.to_s.delete_prefix('medelement:reception:').presence
  end

  def medelement_outbound_actor?
    actor.is_a?(User) ||
      (defined?(Captain::Assistant) && actor.is_a?(Captain::Assistant) && actor.account_id == account.id)
  end

  def writable_medelement_hook?
    hook = account.hooks.enabled.find_by(app_id: 'medelement')
    hook&.feature_allowed? && Integrations::Medelement::Configuration.new(hook: hook).write_enabled?
  end

  def resolve_company(contact)
    return appointment.company if appointment.persisted? && !company_attachment_enabled? && !params.key?(:company_id)
    return nil unless company_attachment_enabled?

    resolve_optional_record(:company_id, account.companies, current: appointment.company || contact&.company)
  end

  def resolve_owner(contact:, resource:)
    return resolve_optional_record(:owner_id, account.users, current: appointment.owner) if params.key?(:owner_id)
    return appointment.owner if appointment.persisted?

    contact&.owner || resource&.user || user_actor
  end

  def resolve_custom_attributes(resource:, services:)
    incoming = params[:custom_attributes]
    catalog = appointment_field_catalog
    resolved_attributes = if catalog.definitions.blank?
                            resolve_unmanaged_custom_attributes(incoming)
                          else
                            resolve_managed_custom_attributes(incoming, catalog)
                          end

    attributes = apply_intake_system_custom_attributes(resolved_attributes, incoming)
    attributes = clear_local_service_binding(attributes) if explicit_service_selection?
    attributes.merge(service_custom_attributes(services))
              .merge(local_service_binding_attributes(resource, services))
  end

  def resolve_unmanaged_custom_attributes(incoming)
    current_attributes = current_custom_attributes_without_service_metadata
    return current_attributes if incoming.nil?

    attributes = incoming.to_h.deep_stringify_keys
    validate_protected_system_custom_attributes!(attributes, current_attributes)
    CustomAttributes::MutationService.merge(
      current_attributes,
      sanitized_system_custom_attributes(attributes, current_attributes)
    )
  end

  def resolve_managed_custom_attributes(incoming, catalog)
    current_attributes = current_custom_attributes_without_service_metadata
    existing_unmanaged_attributes = current_attributes.except(*catalog.definitions.map(&:key))
    existing_unmanaged_attributes.merge(
      preserved_system_custom_attributes,
      catalog.resolve_custom_attributes(
        current_attributes: current_attributes,
        incoming_attributes: catalog_custom_attributes(incoming, current_attributes),
        apply_defaults: appointment.new_record?
      )
    )
  end

  def service_custom_attributes(services)
    return {} if services.blank?

    {
      'service_ids' => services.map(&:id),
      'services' => services.map do |service|
        {
          'id' => service.id,
          'name' => service.name,
          'service_type' => service.service_type,
          'duration_min' => service.duration_min
        }
      end
    }
  end

  def local_service_binding_attributes(resource, services)
    return {} unless explicit_service_selection? || appointment.new_record?
    return {} if resource.custom_attributes.to_h['medelement_specialist_code'].blank?
    return {} if services.blank?

    codes = services.filter_map do |service|
      service.custom_attributes.to_h['medelement_nomenclature_code'].presence
    end
    Integrations::Medelement::AppointmentServiceBinding.new(appointment: appointment).local_only_attributes(codes)
  end

  def clear_local_service_binding(attributes)
    attributes.except(*Integrations::Medelement::AppointmentServiceBinding::ATTRIBUTE_KEYS)
  end

  def explicit_service_selection?
    params.key?(:service_ids) || params.key?(:service_id)
  end

  def appointment_field_catalog
    @appointment_field_catalog ||= Crm::FieldCatalog.new(
      account: account,
      entity_kind: 'appointment',
      context: appointment_field_context
    )
  end

  def appointment_field_context
    return APPOINTMENT_BOOKING_INTAKE_CONTEXT if appointment.new_record?
    return APPOINTMENT_BOOKING_INTAKE_CONTEXT if params.key?(:custom_attributes)

    nil
  end

  def apply_intake_system_custom_attributes(resolved_attributes, incoming)
    return resolved_attributes if incoming.nil?

    attributes = incoming.to_h.deep_stringify_keys
    INTAKE_SYSTEM_CUSTOM_ATTRIBUTE_KEYS.each do |key|
      next unless attributes.key?(key)

      value = attributes[key].to_s.strip.presence
      value.nil? ? resolved_attributes.delete(key) : resolved_attributes[key] = value
    end
    resolved_attributes
  end

  def catalog_custom_attributes(incoming, current_attributes)
    return if incoming.nil?

    attributes = incoming.to_h.deep_stringify_keys
    validate_protected_system_custom_attributes!(attributes, current_attributes)
    sanitized_system_custom_attributes(attributes, current_attributes)
  end

  def sanitized_system_custom_attributes(attributes, current_attributes)
    attributes.except(
      *DERIVED_SYSTEM_CUSTOM_ATTRIBUTE_KEYS,
      *INTAKE_SYSTEM_CUSTOM_ATTRIBUTE_KEYS,
      *unchanged_protected_system_custom_attribute_keys(attributes, current_attributes)
    )
  end

  def unchanged_protected_system_custom_attribute_keys(attributes, current_attributes)
    attributes.keys.select do |key|
      protected_system_custom_attribute_key?(key) &&
        current_attributes.key?(key) &&
        current_attributes[key] == attributes[key]
    end
  end

  def validate_protected_system_custom_attributes!(attributes, current_attributes)
    changed_key = attributes.keys.find do |key|
      protected_system_custom_attribute_key?(key) &&
        INTAKE_SYSTEM_CUSTOM_ATTRIBUTE_KEYS.exclude?(key) &&
        current_attributes[key] != attributes[key]
    end
    return if changed_key.blank?

    raise Crm::Error.new(
      code: 'VALIDATION_ERROR',
      message: "custom_attributes.#{changed_key} is managed by the system",
      status: :unprocessable_content,
      details: { "custom_attributes.#{changed_key}" => ['is managed by the system'] }
    )
  end

  def protected_system_custom_attribute_key?(key)
    PRESERVED_SYSTEM_CUSTOM_ATTRIBUTE_KEYS.include?(key) ||
      PRESERVED_SYSTEM_CUSTOM_ATTRIBUTE_PREFIXES.any? { |prefix| key.start_with?(prefix) }
  end

  def preserved_system_custom_attributes
    appointment.custom_attributes
               .to_h
               .deep_stringify_keys
               .select { |key, _value| protected_system_custom_attribute_key?(key) }
  end

  def current_custom_attributes_without_service_metadata
    appointment.custom_attributes
               .to_h
               .deep_stringify_keys
               .except('service_ids', 'services')
  end

  def resolve_date(key, current:)
    value = params[key]
    return current unless params.key?(key)
    return nil if value.blank?

    value.is_a?(Date) ? value : Date.iso8601(value.to_s)
  rescue Date::Error
    raise ArgumentError, "#{key} must be YYYY-MM-DD"
  end

  def resolve_datetime(key, current:)
    value = params[key]
    return current unless params.key?(key)
    raise ArgumentError, "#{key} is required" if value.blank?

    Time.zone.parse(value.to_s) || raise(ArgumentError, "#{key} must be a valid datetime")
  end

  def resolve_duration_min(starts_at:, resource:, services:, current_duration_min:)
    explicit_duration = if params.key?(:duration_min)
                          resolve_int(:duration_min,
                                      current: current_duration_min || resource.slot_duration_min || 30)
                        end
    explicit_ends_at = params.key?(:ends_at) ? resolve_datetime(:ends_at, current: appointment.ends_at) : nil

    if explicit_duration.present? && explicit_ends_at.present?
      expected_ends_at = starts_at + explicit_duration.minutes
      raise ArgumentError, 'duration_min does not match ends_at' unless expected_ends_at == explicit_ends_at
    end

    return explicit_duration if explicit_duration.present?
    return [((explicit_ends_at - starts_at) / 60).round, 5].max if explicit_ends_at.present?

    service_duration = services.sum { |service| service.duration_min.to_i }
    return service_duration if service_duration.positive?
    return current_duration_min.to_i if current_duration_min.to_i.positive?

    [resource.slot_duration_min.to_i, 5].max
  end

  def resolve_ends_at(starts_at:, duration_min:, current:)
    return current unless starts_at.present?

    explicit_ends_at = params.key?(:ends_at) ? resolve_datetime(:ends_at, current: current) : nil
    ends_at = explicit_ends_at || (starts_at + duration_min.minutes)
    raise ArgumentError, 'ends_at must be greater than starts_at' if ends_at <= starts_at

    ends_at
  end

  def resolve_int(key, current:)
    return current.to_i unless params.key?(key)

    Scheduling::IntegerNumericNormalizer.normalize_or_zero(params[key], field_name: key)
  end

  def auto_apply_default_touch_plan!
    Reminders::DefaultPlanService.new(
      account: account,
      remindable: appointment,
      actor: actor
    ).perform
  end

  def notify_assignment!(new_record:)
    return unless new_record || appointment.previous_changes.key?('resource_id')

    ::Crm::AssignmentNotificationService.new(
      account: account,
      record: appointment,
      user: appointment.resource&.user,
      notification_type: 'appointment_assignment',
      actor: actor
    ).perform
  end

  def sync_or_cancel_related_touches!
    return cancel_related_touches! if appointment.status == 'cancelled'

    Reminders::SyncRemindableService.new(remindable: appointment).perform
  end

  def cancel_related_touches!
    Reminders::BulkCancelService.new(
      account: account,
      remindable: appointment,
      actor: actor,
      reason: 'отменен из-за отмены записи',
      metadata: { cancelled_via: 'appointment_cancelled' }
    ).perform
  end

  def resolve_optional_record(key, scope, current:)
    return current unless params.key?(key)
    return nil if params[key].blank?

    scope.find(params[key])
  end

  def resolve_conversation
    if params.key?(:conversation_id)
      return nil if params[:conversation_id].blank?

      return account.conversations.find_by(id: params[:conversation_id]) ||
             account.conversations.find_by!(display_id: params[:conversation_id])
    end
    return resolve_conversation_by_display_id if params.key?(:conversation_display_id)

    appointment.conversation
  end

  def resolve_conversation_by_display_id
    return nil if params[:conversation_display_id].blank?

    account.conversations.find_by!(display_id: params[:conversation_display_id])
  end

  def ensure_conversation_belongs_to_contact!(conversation, contact)
    return unless conversation_contact_validation_required?
    return if conversation.blank?
    return if contact.present? && conversation.contact_id == contact.id

    raise Scheduling::Error.new(
      code: 'CONVERSATION_CONTACT_MISMATCH',
      message: 'Conversation must belong to the selected contact',
      status: :unprocessable_content
    )
  end

  def conversation_contact_validation_required?
    params.key?(:conversation_id) || params.key?(:conversation_display_id) || params.key?(:contact_id)
  end

  def resolve_services(current:)
    ids = normalized_service_ids(current: current)
    return [] if ids.blank?

    records_by_id = account.scheduling_services.where(id: ids).index_by(&:id)
    missing_id = ids.find { |id| !records_by_id.key?(id) }
    raise ActiveRecord::RecordNotFound, "service #{missing_id} not found" if missing_id

    ids.map { |id| records_by_id.fetch(id) }
  end

  def normalized_service_ids(current:)
    return normalize_ids(params[:service_ids]) if params.key?(:service_ids)
    return normalize_ids([params[:service_id]]) if params.key?(:service_id)

    current.map(&:id)
  end

  def normalize_ids(values)
    Array(values).filter_map do |value|
      text = value.to_s.strip
      text.present? ? Integer(text) : nil
    end.uniq
  rescue ArgumentError, TypeError
    raise ArgumentError, 'service_ids must be integers'
  end

  def resolve_optional_text(key, current:)
    return current unless params.key?(key)

    text = params[key].to_s.strip
    text.presence
  end

  def resolve_resource!
    if params.key?(:resource_id)
      return appointment.resource if keep_current_resource?(params[:resource_id])

      resource = account.scheduling_resources.find(params[:resource_id])
      ensure_resource_available_for_scheduling!(resource)
      return resource
    end

    return appointment.resource if appointment.resource.present?

    raise ActiveRecord::RecordNotFound, 'resource not found'
  end

  def resolve_service_amount(resource:, services:, resolved_price:)
    return resolve_int(:service_amount, current: appointment.service_amount || 0) if params.key?(:service_amount)
    return 0 if services.blank?

    pricing_changed = pricing_link_changed?(resource: resource, services: services)
    return resolved_price if resolved_price.present? && pricing_changed

    current_amount = appointment.service_amount.to_i
    return current_amount if appointment.persisted? && !pricing_changed
    return current_amount if current_amount.positive?
    return resolved_price if resolved_price.present?

    raise ArgumentError, 'service_amount is required and must be greater than 0'
  end

  def resolve_service_snapshot(resource:, services:)
    if services.blank?
      return {
        resolved_price: nil,
        service_name_snapshot: resolve_optional_text(
          :service_name_snapshot,
          current: appointment.service_name_snapshot
        ),
        service_type_snapshot: nil,
        service_duration_min_snapshot: nil,
        compensation_type_snapshot: resource.compensation_type,
        compensation_value_snapshot: resource.compensation_value,
        compensation_percent_snapshot: resource.compensation_percent
      }
    end

    return resolve_single_service_snapshot(resource: resource, service: services.first) if services.one?

    items = services.map { |service| resolve_single_service_snapshot(resource: resource, service: service) }
    total_expense = items.sum { |item| compute_snapshot_expense_amount(item) }

    {
      resolved_price: items.sum { |item| item[:resolved_price].to_i },
      service_name_snapshot: services.map(&:name).join(', '),
      service_type_snapshot: services.map(&:service_type).filter_map(&:presence).uniq.join(', ').presence,
      service_duration_min_snapshot: services.sum { |service| service.duration_min.to_i },
      compensation_type_snapshot: 'fixed',
      compensation_value_snapshot: total_expense,
      compensation_percent_snapshot: 0
    }
  end

  def resolve_single_service_snapshot(resource:, service:)
    price = service.prices.find_by(resource_id: resource.id)
    resolved_price = if price&.active? && price.price.to_i.positive?
                       price.price
                     else
                       service.base_price
                     end

    if !service.active? || resolved_price.to_i <= 0
      raise Scheduling::Error.new(
        code: 'SERVICE_NOT_AVAILABLE_FOR_RESOURCE',
        message: 'Service is not available for the selected resource',
        status: :unprocessable_content
      )
    end

    compensation_type = if price&.active? && price.price.to_i.positive?
                          price.compensation_type
                        else
                          resource.compensation_type
                        end
    compensation_value = if price&.active? && price.price.to_i.positive?
                           price.compensation_value
                         else
                           resource.compensation_value
                         end
    compensation_percent = if price&.active? && price.price.to_i.positive?
                             price.compensation_percent
                           else
                             resource.compensation_percent
                           end

    {
      resolved_price: resolved_price,
      service_name_snapshot: service.name,
      service_type_snapshot: service.service_type,
      service_duration_min_snapshot: service.duration_min,
      compensation_type_snapshot: compensation_type,
      compensation_value_snapshot: compensation_value,
      compensation_percent_snapshot: compensation_percent
    }
  end

  def compute_snapshot_expense_amount(snapshot)
    service_amount = snapshot[:resolved_price].to_i

    case snapshot[:compensation_type_snapshot]
    when 'fixed'
      snapshot[:compensation_value_snapshot].to_i
    when 'fixed_plus_percent'
      snapshot[:compensation_value_snapshot].to_i +
        ((service_amount * snapshot[:compensation_percent_snapshot].to_i) / 100.0).round
    when 'percent'
      ((service_amount * snapshot[:compensation_value_snapshot].to_i) / 100.0).round
    else
      0
    end
  end

  def resolve_string(key, current:)
    value = params[key]
    return current.to_s unless params.key?(key)

    text = value.to_s.strip
    raise ArgumentError, "#{key} is required" if text.blank?

    text
  end

  def pricing_link_changed?(resource:, services:)
    return true if appointment.new_record?

    appointment.resource_id != resource.id ||
      current_service_ids != services.map(&:id)
  end

  def current_service_ids
    stored_ids = appointment.custom_attributes.to_h['service_ids']
    normalized_ids = normalize_ids(stored_ids)
    return normalized_ids if normalized_ids.present?

    appointment.service_id.present? ? [appointment.service_id] : []
  end

  def current_services
    ids = current_service_ids
    return [] if ids.blank?

    records_by_id = account.scheduling_services.where(id: ids).index_by(&:id)
    ids.filter_map do |id|
      records_by_id[id] || (appointment.service if appointment.service_id == id)
    end
  end

  def keep_current_resource?(resource_id)
    appointment.persisted? &&
      appointment.resource.present? &&
      appointment.resource_id == resource_id.to_i
  end

  def ensure_resource_available_for_scheduling!(resource)
    return if resource.active? && !resource.deleted_from_scheduling?

    raise Scheduling::Error.new(
      code: 'RESOURCE_NOT_AVAILABLE_FOR_SCHEDULING',
      message: 'Specialist is not available for scheduling',
      status: :unprocessable_content
    )
  end

  def ensure_contact_present!(contact)
    return unless contact_required?
    return if contact.present?

    raise ArgumentError, 'contact_id is required'
  end

  def contact_required?
    account.scheduling_contact_required?
  end

  def company_attachment_enabled?
    account.scheduling_company_enabled?
  end

  def validate_availability!
    return if appointment.status == 'cancelled'
    return unless availability_validation_required?

    result = availability_service.availability_result(starts_at: appointment.starts_at, ends_at: appointment.ends_at)
    if result.available?
      validate_provider_availability!
      return
    end

    raise Scheduling::Error.new(
      code: result.code,
      message: result.message,
      status: result.code == 'VALIDATION_ERROR' ? :unprocessable_content : :conflict
    )
  end

  def validate_provider_availability!
    return unless medelement_resource?

    result = Integrations::Medelement::ResourceAvailabilityService.new(
      resource: appointment.resource,
      from: appointment.starts_at,
      to: appointment.ends_at,
      slots: [provider_candidate_slot],
      cabinet_code: appointment.custom_attributes.to_h['medelement_cabinet_code'],
      exclude_reception_code: medelement_reception_code
    ).perform
    return if result.status == 'fresh' && result.slots.one?

    raise provider_availability_error(result)
  end

  def provider_candidate_slot
    {
      resource_id: appointment.resource_id,
      starts_at: appointment.starts_at.iso8601,
      ends_at: appointment.ends_at.iso8601
    }
  end

  def provider_availability_error(result)
    provider_unavailable = result.status != 'fresh'
    Scheduling::Error.new(
      code: provider_unavailable ? 'MEDELEMENT_AVAILABILITY_UNVERIFIED' : 'APPOINTMENT_SLOT_UNAVAILABLE',
      message: provider_unavailable ? 'Medelement availability could not be verified' : 'Appointment slot is unavailable in Medelement',
      status: provider_unavailable ? :service_unavailable : :conflict,
      details: { provider_reason: result.reason, provider_checked_at: result.checked_at.iso8601(6) }.compact
    )
  end

  def availability_validation_required?
    return true if appointment.new_record?
    return true if appointment.will_save_change_to_resource_id?
    return true if appointment.will_save_change_to_starts_at?
    return true if appointment.will_save_change_to_ends_at?
    return true if medelement_cabinet_change?

    appointment.will_save_change_to_status? &&
      appointment.attribute_in_database('status') == 'cancelled'
  end

  def medelement_cabinet_change?
    previous, current = appointment.changes_to_save['custom_attributes']
    return false if previous.blank? && current.blank?

    previous.to_h['medelement_cabinet_code'] != current.to_h['medelement_cabinet_code']
  end
end
