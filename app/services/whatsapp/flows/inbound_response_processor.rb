# frozen_string_literal: true

class Whatsapp::Flows::InboundResponseProcessor # rubocop:disable Metrics/ClassLength
  GENERIC_FLOW_BODIES = ['Sent', 'WhatsApp form response'].freeze
  CLIENT_PARAM_MAP = {
    client_first_name: :client_first_name,
    client_last_name: :client_last_name,
    client_middle_name: :client_middle_name,
    client_phone: :client_phone,
    client_birth_date: :client_birth_date,
    client_identifier: :client_iin,
    client_comment: :notes
  }.freeze

  def initialize(inbox:, message:)
    @inbox = inbox
    @message = message
    @account = inbox&.account
    @conversation = message&.conversation
  end

  def perform
    return if skip_processing?

    response_data = extract_response_data
    return if response_data.nil?

    if clinic_intake_submission?(response_data)
      process_clinic_intake_submission(response_data)
    else
      process_booking_submission(response_data)
    end
  rescue Scheduling::Error, Crm::Error => e
    handle_processing_exception(e, response_data, e.code, e.message)
  rescue ActiveRecord::RecordInvalid, ArgumentError => e
    handle_processing_exception(e, response_data, 'BOOKING_VALIDATION_FAILED', e.message)
  rescue StandardError => e
    handle_processing_exception(e, response_data, 'BOOKING_PROCESSING_FAILED', 'Could not finalize booking automatically')
  end

  private

  attr_reader :inbox, :message, :account, :conversation

  def resolver
    @resolver ||= Whatsapp::Flows::BookingSlotResolver.new(account: account)
  end

  def process_booking_submission(response_data)
    raw_token = response_data['flow_token'].to_s.strip
    token_check = Whatsapp::Flows::TokenService.verify_flow_token(raw_token, channel: inbox.channel)
    return unless booking_submission?(response_data, token_check)

    auth_failure = authorize_booking_token(token_check)
    return persist_booking_failure!(response_data, auth_failure[:code], auth_failure[:message]) if auth_failure

    verified_booking = verify_booking_selection!(response_data, token_check)
    appointment = find_or_create_appointment!(verified_booking)
    persist_booking_success!(appointment, response_data, token_check)
  end

  def handle_processing_exception(error, response_data, code, error_message)
    log_booking_failure(error)
    persist_booking_failure!(response_data || {}, code, error_message)
  end

  def skip_processing?
    return true unless valid_whatsapp_message_context?
    return true if message.content_attributes.to_h['whatsapp_flow_response'].blank?

    attrs = message.content_attributes.to_h
    attrs['whatsapp_flow_booking'].present? || attrs['whatsapp_flow_intake'].present?
  end

  def valid_whatsapp_message_context?
    inbox.present? && account.present? && message.present? && conversation.present? &&
      message.incoming? && inbox.channel.is_a?(Channel::Whatsapp)
  end

  def extract_response_data
    flow_response = message.content_attributes.to_h['whatsapp_flow_response']
    return nil unless flow_response.is_a?(Hash)

    data = flow_response['response']
    return nil unless data.is_a?(Hash) && !data['_invalid_json']

    data.deep_stringify_keys
  end

  def clinic_intake_submission?(response_data)
    response_data['onelink_flow_kind'].to_s == 'clinic_intake'
  end

  def process_clinic_intake_submission(response_data)
    req_title = Whatsapp::Flows::ClinicIntakeFlowSchemaBuilder.request_type_title(response_data['request_type'])
    full_name = response_data['client_full_name'].to_s.strip
    iin = Scheduling::IinValidator.normalize(response_data['client_iin'])
    visit_date = response_data['visit_date'].to_s.strip
    details = response_data['details'].to_s.strip

    update_contact_from_intake!(full_name, iin)

    intake_summary = {
      'status' => 'received',
      'clinic_preset' => response_data['clinic_preset'].to_s.presence || Whatsapp::Flows::ClinicProfile.detect_preset(account),
      'request_type' => response_data['request_type'].to_s,
      'request_title' => req_title,
      'client_full_name' => full_name.presence,
      'client_iin' => iin.presence,
      'visit_date' => visit_date.presence,
      'details' => details.presence
    }.compact

    attrs = message.content_attributes.to_h.deep_stringify_keys.merge('whatsapp_flow_intake' => intake_summary)
    summary_parts = [
      req_title.present? ? "Заявка: #{req_title}" : 'Заявка через WhatsApp Flow',
      full_name.present? ? "ФИО: #{full_name}" : nil,
      iin.present? ? "ИИН: #{iin}" : nil,
      visit_date.present? ? "Дата: #{visit_date}" : nil,
      details.present? ? "Детали: #{details}" : nil
    ].compact

    updates = { content_attributes: attrs }
    updates[:content] = summary_parts.join(' • ') if generic_flow_body?(message.content)
    message.update!(updates)

    create_intake_registrar_note!(summary_parts)
    intake_summary
  end

  def update_contact_from_intake!(full_name, iin)
    contact = conversation.contact
    return if contact.blank?

    custom = contact.custom_attributes.to_h.deep_dup
    custom['iin'] = iin if iin.present?
    contact_updates = { custom_attributes: custom }
    contact_updates[:name] = full_name if full_name.present? && (contact.name.blank? || contact.name.to_s.match?(/\A\+?\d[\d\s()-]+\z/))
    contact.update(contact_updates)
  end

  def create_intake_registrar_note!(summary_parts)
    conversation.messages.create!(
      account: account,
      inbox: inbox,
      message_type: :activity,
      private: true,
      content: "📋 Заполнена форма пациента (WhatsApp Flow):\n#{summary_parts.join("\n")}"
    )
  rescue StandardError => e
    Rails.logger.warn("[WHATSAPP_FLOWS] Failed to create intake note: #{e.class}: #{e.message}")
  end

  def booking_submission?(response_data, token_check)
    return true if response_data['onelink_flow_kind'].to_s == 'booking'
    return true if response_data['booking_grant'].present?

    token_check[:valid] &&
      token_check.dig(:payload, :kind).to_s == 'booking' &&
      response_data['resource_id'].present? &&
      response_data['starts_at'].present?
  end

  def authorize_booking_token(token_check)
    unless token_check[:valid] && token_check.dig(:payload, :kind).to_s == 'booking'
      reason = token_check[:reason] || 'unverified'
      return { code: 'INVALID_FLOW_TOKEN', message: "Invalid or expired flow token (#{reason})" }
    end

    authorize_payload_actor(token_check[:payload], 'FLOW_TOKEN')
  end

  def authorize_payload_actor(payload, prefix)
    expected_contact_id = payload[:contact_id]
    if expected_contact_id.present? &&
       (conversation.contact_id.blank? || expected_contact_id.to_i != conversation.contact_id.to_i)
      return { code: "#{prefix}_CONTACT_MISMATCH", message: 'Flow token belongs to another contact' }
    end

    expected_conv_id = payload[:conversation_id]
    if expected_conv_id.present? && expected_conv_id.to_i != conversation.id.to_i
      return { code: "#{prefix}_CONVERSATION_MISMATCH", message: 'Flow token belongs to another conversation' }
    end

    nil
  end

  def verify_booking_selection!(response_data, token_check)
    slot_selection = resolve_verified_slot!(response_data)
    client_attrs = validate_client_submission!(slot_selection[:resource], response_data, token_check)
    slot_selection.merge(client_attrs: client_attrs)
  end

  def resolve_verified_slot!(response_data)
    return resolve_granted_slot!(response_data['booking_grant']) if response_data['booking_grant'].present?

    resolve_ungranted_slot!(response_data)
  end

  def resolve_granted_slot!(raw_grant)
    grant_check = Whatsapp::Flows::TokenService.verify_booking_grant(raw_grant, channel: inbox.channel)
    raise_booking_error!('INVALID_BOOKING_GRANT', 'Invalid or expired booking confirmation grant') unless grant_check[:valid]

    grant = grant_check[:payload]
    actor_err = authorize_payload_actor(grant, 'BOOKING_GRANT')
    raise_booking_error!(actor_err[:code], actor_err[:message]) if actor_err

    resource, service = resolve_resource_and_service!(grant[:resource_id], grant[:service_id])
    starts_at = require_valid_window!(resource, grant[:starts_at], enforce_lead_time: false)

    {
      resource: resource, service: service, starts_at: starts_at,
      duration_min: grant[:duration_min], cabinet_code: grant[:cabinet_code]
    }
  end

  def resolve_ungranted_slot!(response_data)
    resource, service = resolve_resource_and_service!(response_data['resource_id'], response_data['service_id'])
    starts_at = require_valid_window!(resource, response_data['starts_at'], enforce_lead_time: true)
    cabinet_code = verify_slot_available_or_medelement!(resource, service, starts_at, response_data)

    {
      resource: resource, service: service, starts_at: starts_at,
      duration_min: resolver.duration_for(resource: resource, service: service),
      cabinet_code: cabinet_code
    }
  end

  def verify_slot_available_or_medelement!(resource, service, starts_at, response_data)
    medelement = resource.custom_attributes.to_h['medelement_specialist_code'].present?
    return response_data['medelement_cabinet_code'].to_s.strip.presence if medelement

    resolved = resolver.resolve_slot_key("#{resource.id}@#{starts_at.iso8601}", service: service)
    raise_booking_error!('SLOT_NOT_AVAILABLE', 'Selected time slot is not available') if resolved.nil?

    resolved[:cabinet_code]
  end

  def resolve_resource_and_service!(raw_resource_id, raw_service_id)
    resource = resolver.find_resource(raw_resource_id)
    raise_booking_error!('RESOURCE_NOT_AVAILABLE', 'Specialist is not available for booking') unless resource

    service = lookup_requested_service!(raw_service_id, resource)
    [resource, service]
  end

  def lookup_requested_service!(raw_service_id, resource)
    return nil if raw_service_id.blank? || %w[none any].include?(raw_service_id.to_s)

    service = resolver.find_service(raw_service_id)
    if service.nil? || !resolver.resource_supports_service?(resource, service)
      raise_booking_error!('SERVICE_NOT_AVAILABLE', 'Selected service is not available for this specialist')
    end

    service
  end

  def require_valid_window!(resource, raw_starts_at, enforce_lead_time:)
    starts_at = resolver.parse_time(raw_starts_at)
    raise_booking_error!('INVALID_STARTS_AT', 'Booking start time is invalid') if starts_at.blank?

    unless resolver.within_booking_window?(resource: resource, starts_at: starts_at, enforce_lead_time: enforce_lead_time)
      raise_booking_error!('SLOT_OUT_OF_WINDOW', 'Booking time is outside the allowed scheduling window')
    end

    starts_at
  end

  def validate_client_submission!(resource, response_data, token_check)
    validator = Whatsapp::Flows::BookingClientValidator.new(
      account: account,
      resource: resource,
      locale: resolved_locale(token_check),
      contact: conversation.contact
    )
    result = validator.validate_submission(response_data)
    raise_booking_error!('CLIENT_VALIDATION_FAILED', result[:error]) unless result[:valid]

    result[:attributes]
  end

  def raise_booking_error!(code, error_message)
    raise Scheduling::Error.new(code: code, message: error_message, status: :unprocessable_content)
  end

  def idempotency_key
    "wa_flow:#{message.source_id.presence || message.id}"
  end

  def find_or_create_appointment!(verified_booking)
    existing = account.scheduling_appointments.find_by(idempotency_key: idempotency_key)
    return existing if existing.present?

    Scheduling::Appointments::UpsertService.new(
      account: account,
      actor: inbox.channel,
      params: build_upsert_params(verified_booking)
    ).perform
  rescue ActiveRecord::RecordNotUnique
    account.scheduling_appointments.find_by!(idempotency_key: idempotency_key)
  end

  def build_upsert_params(verified_booking)
    params = {
      resource_id: verified_booking[:resource].id,
      starts_at: verified_booking[:starts_at].iso8601,
      duration_min: verified_booking[:duration_min],
      contact_id: conversation.contact_id,
      conversation_id: conversation.id,
      idempotency_key: idempotency_key
    }
    assign_service_params!(params, verified_booking[:service])
    assign_validated_client_params!(params, verified_booking[:client_attrs])
    assign_custom_attributes!(params, verified_booking[:cabinet_code])
    params
  end

  def assign_service_params!(params, service)
    return unless service

    params[:service_id] = service.id
    params[:service_ids] = [service.id]
  end

  def assign_validated_client_params!(params, client_attrs)
    CLIENT_PARAM_MAP.each do |target_key, source_key|
      val = client_attrs[source_key]
      params[target_key] = val if val.present?
    end
  end

  def assign_custom_attributes!(params, cabinet_code)
    cleaned = cabinet_code.to_s.strip
    return if cleaned.blank?

    params[:custom_attributes] = { 'medelement_cabinet_code' => cleaned }
  end

  def persist_booking_success!(appointment, response_data, token_check)
    outcome = build_success_outcome(appointment, response_data)
    attrs = message.content_attributes.to_h.deep_stringify_keys.merge('whatsapp_flow_booking' => outcome)
    updates = { content_attributes: attrs }
    updates[:content] = formatted_booking_message_content(outcome, token_check) if generic_flow_body?(message.content)

    message.update!(updates)
    appointment
  end

  def build_success_outcome(appointment, response_data)
    {
      'status' => 'booked',
      'appointment_id' => appointment.id,
      'resource_id' => appointment.resource_id,
      'resource_name' => appointment.resource&.name.presence || response_data['resource_name'],
      'service_id' => appointment.service_id,
      'service_name' => resolved_service_name(appointment, response_data),
      'starts_at' => appointment.starts_at&.iso8601,
      'ends_at' => appointment.ends_at&.iso8601,
      'duration_min' => appointment.duration_min,
      'slot_label' => format_appointment_slot(appointment) || response_data['slot_label']
    }.compact
  end

  def resolved_service_name(appointment, response_data)
    appointment.service_name_snapshot.presence || appointment.service&.name.presence || response_data['service_name']
  end

  def resolved_locale(token_check)
    token_check.dig(:payload, :locale).presence ||
      inbox.channel.provider_config.to_h.dig('whatsapp_flows', 'booking_locale')
  end

  def formatted_booking_message_content(outcome, token_check)
    copy = Whatsapp::Flows::BookingFlowCopy.for_locale(resolved_locale(token_check), account: account)
    summary = [outcome['service_name'], outcome['resource_name'], outcome['slot_label']].compact_blank.join(' • ')
    summary.present? ? "#{copy[:booking_screen_title]}: #{summary}" : copy[:booking_screen_title]
  end

  def persist_booking_failure!(response_data, error_code, error_message)
    outcome = {
      'status' => 'failed',
      'error_code' => error_code.to_s,
      'error_message' => sanitize_error_message(error_message),
      'resource_name' => response_data['resource_name'],
      'service_name' => response_data['service_name'],
      'slot_label' => response_data['slot_label'],
      'starts_at' => response_data['starts_at']
    }.compact

    attrs = message.content_attributes.to_h.deep_stringify_keys.merge('whatsapp_flow_booking' => outcome)
    message.update!(content_attributes: attrs)
    nil
  end

  def format_appointment_slot(appointment)
    return nil if appointment.starts_at.blank?

    zone = appointment_timezone(appointment)
    local_start = appointment.starts_at.in_time_zone(zone)
    return local_start.strftime('%d.%m.%Y %H:%M') if appointment.ends_at.blank?

    "#{local_start.strftime('%d.%m.%Y %H:%M')}–#{appointment.ends_at.in_time_zone(zone).strftime('%H:%M')}"
  end

  def appointment_timezone(appointment)
    tz_name = appointment.resource&.timezone.presence ||
              account.reporting_timezone.presence ||
              Scheduling::Constants::DEFAULT_TIMEZONE
    ActiveSupport::TimeZone[tz_name] || ActiveSupport::TimeZone[Scheduling::Constants::DEFAULT_TIMEZONE]
  end

  def generic_flow_body?(content)
    text = content.to_s.strip
    text.empty? || GENERIC_FLOW_BODIES.include?(text)
  end

  def sanitize_error_message(raw_message)
    Meta::CredentialDataSanitizer.sanitize(
      raw_message.to_s.truncate(240),
      secrets: Meta::CredentialDataSanitizer.channel_secrets(inbox.channel)
    )
  end

  def log_booking_failure(error)
    Rails.logger.warn(
      "[WHATSAPP_FLOWS] inbound booking failed inbox_id=#{inbox&.id} message_id=#{message&.id} " \
      "error_class=#{error.class} error=#{sanitize_error_message(error.message)}"
    )
  end
end
