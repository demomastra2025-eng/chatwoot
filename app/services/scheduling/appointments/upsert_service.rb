class Scheduling::Appointments::UpsertService
  APPOINTMENT_BOOKING_INTAKE_CONTEXT = 'booking_intake'.freeze
  PRESERVED_SYSTEM_CUSTOM_ATTRIBUTE_KEYS = %w[source_mode].freeze
  PRESERVED_SYSTEM_CUSTOM_ATTRIBUTE_PREFIXES = %w[medelement_].freeze

  def initialize(account:, params:, appointment: nil, actor: nil)
    @account = account
    @params = params.to_h.deep_symbolize_keys
    @appointment = appointment || account.scheduling_appointments.new
    @actor = actor
  end

  def perform
    ApplicationRecord.transaction do
      apply_attributes!
      validate_availability!
      new_record = appointment.new_record?
      appointment.save!
      notify_assignment!(new_record: new_record)
      auto_apply_default_touch_plan! if new_record
      sync_related_touches!
      Scheduling::Appointments::FinanceSyncService.new(appointment: appointment, actor: actor).sync!
      appointment.reload
    end
  end

  private

  attr_reader :account, :actor, :appointment, :params

  def apply_attributes!
    resource = resolve_resource!
    contact = resolve_optional_record(:contact_id, account.contacts, current: appointment.contact)
    ensure_contact_present!(contact)
    services = resolve_services(current: current_services)
    primary_service = services.first
    company = resolve_company(contact)
    conversation = resolve_optional_record(:conversation_id, account.conversations, current: appointment.conversation)
    created_by = resolve_optional_record(:created_by_id, account.users, current: appointment.created_by || actor)
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
      client_name: resolve_client_name(contact),
      client_phone: resolve_client_phone(contact),
      client_identifier: resolve_client_identifier(contact),
      client_birth_date: resolve_client_birth_date(contact),
      client_gender: resolve_client_gender(contact),
      client_comment: resolve_optional_text(:client_comment, current: appointment.client_comment),
      source: resolve_string(:source, current: appointment.source.presence || 'manual'),
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
      custom_attributes: resolve_custom_attributes(services: services)
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

  def resolve_client_phone(contact)
    resolve_optional_text(:client_phone, current: appointment.client_phone || contact&.phone_number)
  end

  def resolve_company(contact)
    return appointment.company if appointment.persisted? && !company_attachment_enabled? && !params.key?(:company_id)
    return nil unless company_attachment_enabled?

    resolve_optional_record(:company_id, account.companies, current: appointment.company || contact&.company)
  end

  def resolve_owner(contact:, resource:)
    return resolve_optional_record(:owner_id, account.users, current: appointment.owner) if params.key?(:owner_id)
    return appointment.owner if appointment.persisted?

    contact&.owner || resource&.user || actor
  end

  def resolve_custom_attributes(services:)
    incoming = params[:custom_attributes]
    catalog = appointment_field_catalog

    if catalog.definitions.blank?
      base_attributes =
        if incoming.nil?
          current_custom_attributes_without_service_metadata
        else
          CustomAttributes::MutationService.merge(
            current_custom_attributes_without_service_metadata,
            incoming
          )
        end

      return base_attributes.to_h.deep_stringify_keys.merge(service_custom_attributes(services))
    end

    current_attributes = current_custom_attributes_without_service_metadata
    existing_unmanaged_attributes = current_attributes.except(*catalog.definitions.map(&:key))

    existing_unmanaged_attributes.merge(
      preserved_system_custom_attributes,
      catalog.resolve_custom_attributes(
        current_attributes: current_attributes,
        incoming_attributes: incoming,
        apply_defaults: appointment.new_record?
      )
    ).merge(service_custom_attributes(services))
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

  def preserved_system_custom_attributes
    appointment.custom_attributes
               .to_h
               .deep_stringify_keys
               .select do |key, _value|
      PRESERVED_SYSTEM_CUSTOM_ATTRIBUTE_KEYS.include?(key) ||
        PRESERVED_SYSTEM_CUSTOM_ATTRIBUTE_PREFIXES.any? { |prefix| key.start_with?(prefix) }
    end
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

  def sync_related_touches!
    Reminders::SyncRemindableService.new(remindable: appointment).perform
  end

  def resolve_optional_record(key, scope, current:)
    return current unless params.key?(key)
    return nil if params[key].blank?

    scope.find(params[key])
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
        service_name_snapshot: nil,
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
    return if result.available?

    raise Scheduling::Error.new(
      code: result.code,
      message: result.message,
      status: result.code == 'VALIDATION_ERROR' ? :unprocessable_content : :conflict
    )
  end

  def availability_validation_required?
    return true if appointment.new_record?
    return true if appointment.will_save_change_to_resource_id?
    return true if appointment.will_save_change_to_starts_at?
    return true if appointment.will_save_change_to_ends_at?

    appointment.will_save_change_to_status? &&
      appointment.attribute_in_database('status') == 'cancelled'
  end
end
