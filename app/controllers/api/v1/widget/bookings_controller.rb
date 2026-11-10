# frozen_string_literal: true

class Api::V1::Widget::BookingsController < Api::V1::Widget::BaseController
  def show
    return render json: { enabled: false }, status: :ok unless booking_enabled?

    validator = client_validator(resolver.available_resources.first)
    render json: {
      enabled: true,
      clinic_preset: clinic_config[:preset],
      clinic_title: clinic_config[:clinic_title],
      specialist_label: clinic_config[:specialist_label].presence || copy[:specialist_label],
      service_label: clinic_config[:service_label].presence || copy[:service_label],
      confirm_cta: clinic_config[:confirm_cta].presence || copy[:confirm_cta],
      notes_helper: clinic_config[:notes_helper],
      show_visit_reason: clinic_config[:show_visit_reason] == true,
      visit_reasons: Array(clinic_config[:visit_reasons]),
      default_visit_reason: clinic_config[:default_visit_reason].to_s,
      services: [],
      specialists: serialized_specialists,
      dates: serialized_dates,
      field_flags: validator.field_flags,
      prefill: validator.prefill_values,
      whatsapp_phone: primary_whatsapp_phone
    }, status: :ok
  end

  def slots
    return render json: { error: 'Online booking is disabled' }, status: :forbidden unless booking_enabled?

    service = nil
    resources = resolver.candidate_resources(params[:resource_id], service: service)
    return render json: { slots: [], error: copy[:no_specialists_error] }, status: :ok if resources.empty?

    date = resolver.parse_booking_date(params[:booking_date])
    available_slots = resolver.slots_for_date(resources: resources, date: date, service: service)
    nearest_date = available_slots.empty? ? resolver.nearest_available_date(resources: resources, after_date: date, service: service) : nil

    render json: {
      booking_date: date.iso8601,
      slots: available_slots.map { |entry| serialize_slot(entry, service) },
      nearest_date: nearest_date&.iso8601,
      nearest_date_label: nearest_date ? Whatsapp::Flows::BookingFlowCopy.format_date(nearest_date, locale: resolved_locale) : nil
    }, status: :ok
  end

  def create
    return render json: { error: 'Online booking is disabled' }, status: :forbidden unless booking_enabled?

    service = nil
    slot = resolver.resolve_slot_key(booking_params[:slot_key], service: service)
    return render json: { error: copy[:slot_taken_error], code: 'SLOT_TAKEN' }, status: :unprocessable_content if slot.nil?

    resource = slot[:resource]
    validation = client_validator(resource).validate_submission(booking_params)
    return render json: { error: validation[:error], code: 'VALIDATION_FAILED' }, status: :unprocessable_content unless validation[:valid]

    client_attrs = validation[:attributes]
    update_widget_contact!(client_attrs)
    active_conv = ensure_widget_conversation!
    appointment = create_calendar_appointment!(resource, service, slot, client_attrs, active_conv)
    post_booking_confirmation_message!(appointment, service, slot, active_conv)

    render json: {
      appointment: serialize_appointment(appointment, service, slot, client_attrs),
      whatsapp_deeplink: build_whatsapp_deeplink(appointment, service, slot, client_attrs)
    }, status: :created
  rescue Scheduling::Error, Crm::Error => e
    render json: { error: e.message, code: e.code }, status: :unprocessable_content
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.to_sentence, code: 'RECORD_INVALID' }, status: :unprocessable_content
  end

  private

  def account
    @account ||= inbox&.account
  end

  def booking_enabled?
    account.present? && account.feature_enabled?('scheduling') && resolver.available_resources.any?
  end

  def resolved_locale
    @resolved_locale ||= Whatsapp::Flows::BookingFlowCopy.normalize_locale(params[:locale] || account&.locale, account: account)
  end

  def copy
    @copy ||= Whatsapp::Flows::BookingFlowCopy.for_locale(resolved_locale, account: account)
  end

  def clinic_config
    @clinic_config ||= Whatsapp::Flows::ClinicProfile.config_for(account: account, preset: params[:clinic_preset])
  end

  def resolver
    @resolver ||= Whatsapp::Flows::BookingSlotResolver.new(account: account)
  end

  def client_validator(resource)
    Whatsapp::Flows::BookingClientValidator.new(
      account: account,
      resource: resource,
      locale: resolved_locale,
      contact: @contact,
      clinic_preset: clinic_config[:preset]
    )
  end

  def serialized_specialists
    resolver.available_resources.map do |res|
      {
        id: res.id.to_s,
        name: res.name,
        specialty: res.custom_attributes.to_h['specialty'].to_s.strip.presence,
        service_ids: []
      }
    end
  end

  def serialized_dates
    resolver.upcoming_dates.map do |date|
      {
        id: date.iso8601,
        label: Whatsapp::Flows::BookingFlowCopy.format_date(date, locale: resolved_locale)
      }
    end
  end

  def serialize_slot(entry, service)
    {
      key: entry[:key],
      time_label: "#{entry[:local_start].strftime('%H:%M')} – #{entry[:local_end].strftime('%H:%M')}",
      start_time: entry[:local_start].strftime('%H:%M'),
      starts_at: entry[:starts_at].iso8601,
      duration_min: entry[:duration_min],
      resource_id: entry[:resource].id.to_s,
      resource_name: entry[:resource].name,
      service_name: service&.name
    }
  end

  def booking_params
    params.fetch(:booking, params).permit(
      :service_id, :resource_id, :booking_date, :slot_key, :visit_reason,
      :client_first_name, :client_last_name, :client_middle_name,
      :client_phone, :client_birth_date, :client_iin, :notes
    )
  end

  def update_widget_contact!(client_attrs)
    return if @contact.blank?

    full_name = [client_attrs[:client_last_name], client_attrs[:client_first_name], client_attrs[:client_middle_name]].compact_blank.join(' ')
    custom = @contact.custom_attributes.to_h.deep_dup
    custom['iin'] = client_attrs[:client_iin] if client_attrs[:client_iin].present?
    custom['birth_date'] = client_attrs[:client_birth_date] if client_attrs[:client_birth_date].present?

    updates = { custom_attributes: custom }
    updates[:name] = full_name if full_name.present?
    if client_attrs[:client_phone].present? && @contact.phone_number.blank?
      existing = account.contacts.find_by(phone_number: client_attrs[:client_phone])
      updates[:phone_number] = client_attrs[:client_phone] if existing.nil? || existing.id == @contact.id
    end
    @contact.update(updates)
  end

  def ensure_widget_conversation!
    return conversation if conversation.present?

    ::Conversation.create!(
      account_id: inbox.account_id,
      inbox_id: inbox.id,
      contact_id: @contact.id,
      contact_inbox_id: @contact_inbox.id,
      additional_attributes: {
        browser_language: browser.accept_language&.first&.code,
        browser: browser_params,
        initiated_at: { timestamp: Time.current.to_s }
      }
    )
  end

  def create_calendar_appointment!(resource, service, slot, client_attrs, active_conv)
    idempotency_key = "widget_booking:#{@contact.id}:#{resource.id}:#{slot[:starts_at].to_i}"
    existing = account.scheduling_appointments.find_by(idempotency_key: idempotency_key)
    return existing if existing.present?

    upsert_params = {
      resource_id: resource.id,
      starts_at: slot[:starts_at].iso8601,
      duration_min: slot[:duration_min],
      contact_id: @contact.id,
      conversation_id: active_conv.id,
      idempotency_key: idempotency_key,
      client_first_name: client_attrs[:client_first_name],
      client_last_name: client_attrs[:client_last_name],
      client_middle_name: client_attrs[:client_middle_name],
      client_phone: client_attrs[:client_phone],
      client_birth_date: client_attrs[:client_birth_date],
      client_identifier: client_attrs[:client_iin],
      client_comment: client_attrs[:notes]
    }.compact

    if service.present?
      upsert_params[:service_id] = service.id
      upsert_params[:service_ids] = [service.id]
    end
    upsert_params[:custom_attributes] = { 'medelement_cabinet_code' => slot[:cabinet_code] } if slot[:cabinet_code].present?

    Scheduling::Appointments::UpsertService.new(
      account: account,
      actor: inbox.channel,
      params: upsert_params
    ).perform
  end

  def post_booking_confirmation_message!(appointment, service, slot, active_conv)
    slot_label = "#{slot[:local_start].strftime('%d.%m.%Y %H:%M')}–#{slot[:local_end].strftime('%H:%M')}"
    summary = [
      "📅 Онлайн-запись через виджет сайта (№#{appointment.id})",
      "Специалист: #{slot[:resource].name}",
      "Дата и время: #{slot_label}"
    ].compact.join(' • ')

    active_conv.messages.create!(
      account_id: account.id,
      inbox_id: inbox.id,
      sender: @contact,
      message_type: :incoming,
      content: summary,
      content_attributes: {
        'widget_booking' => {
          'appointment_id' => appointment.id,
          'resource_id' => slot[:resource].id,
          'resource_name' => slot[:resource].name,
          'service_id' => service&.id,
          'service_name' => service&.name,
          'starts_at' => slot[:starts_at].iso8601,
          'slot_label' => slot_label
        }.compact
      }
    )
  rescue StandardError => e
    Rails.logger.warn("[WIDGET_BOOKING] Failed to post booking message: #{e.class}: #{e.message}")
  end

  def serialize_appointment(appointment, service, slot, client_attrs)
    masked_name = Whatsapp::Flows::BookingClientValidator.mask_name(
      [client_attrs[:client_first_name], client_attrs[:client_last_name]].compact_blank.join(' ')
    )
    masked_phone = Whatsapp::Flows::BookingClientValidator.mask_phone(client_attrs[:client_phone])
    {
      id: appointment.id,
      resource_name: slot[:resource].name,
      service_name: service&.name,
      date_label: slot[:local_start].strftime('%d.%m.%Y'),
      time_label: "#{slot[:local_start].strftime('%H:%M')}–#{slot[:local_end].strftime('%H:%M')}",
      starts_at: slot[:starts_at].iso8601,
      client_name: masked_name,
      client_phone: masked_phone
    }
  end

  def primary_whatsapp_phone
    wa_channel = Channel::Whatsapp.where(account_id: account.id).order(:id).first
    return nil if wa_channel.blank?

    wa_channel.phone_number.to_s.gsub(/\D/, '').presence
  end

  def build_whatsapp_deeplink(appointment, _service, slot, _client_attrs)
    digits = primary_whatsapp_phone
    return nil if digits.blank?

    date_time_str = "#{slot[:local_start].strftime('%d.%m.%Y в %H:%M')}"
    text = "Здравствуйте! Подтверждаю запись №#{appointment.id} на #{date_time_str} к специалисту #{slot[:resource].name}."
    "https://wa.me/#{digits}?text=#{ERB::Util.url_encode(text)}"
  end
end
