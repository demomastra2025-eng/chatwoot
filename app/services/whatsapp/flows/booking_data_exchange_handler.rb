# frozen_string_literal: true

class Whatsapp::Flows::BookingDataExchangeHandler # rubocop:disable Metrics/ClassLength
  TITLE_LIMIT = 30
  DESCRIPTION_LIMIT = 72

  def initialize(channel:, payload:, token_check:)
    @channel = channel
    @account = channel.account
    @payload = payload.to_h.with_indifferent_access
    @token_check = token_check
    @resolver = Whatsapp::Flows::BookingSlotResolver.new(account: @account)
  end

  def perform
    case payload[:action].to_s
    when 'INIT'
      build_booking_step(initial_metadata)
    when 'BACK'
      handle_back_action
    when 'data_exchange'
      handle_data_exchange
    else
      build_booking_step
    end
  end

  private

  attr_reader :channel, :account, :payload, :token_check, :resolver

  def locale
    @locale ||= begin
      raw = token_check.dig(:payload, :locale).presence ||
            channel.provider_config.to_h.dig('whatsapp_flows', 'booking_locale')
      Whatsapp::Flows::BookingFlowCopy.normalize_locale(raw, account: account)
    end
  end

  def copy
    @copy ||= Whatsapp::Flows::BookingFlowCopy.for_locale(locale, account: account)
  end

  def data
    @data ||= payload[:data].is_a?(Hash) ? payload[:data].with_indifferent_access : {}.with_indifferent_access
  end

  def initial_metadata
    token_check[:valid] ? token_check.dig(:payload, :metadata).to_h.with_indifferent_access : {}.with_indifferent_access
  end

  def verified_contact
    return @verified_contact if defined?(@verified_contact)

    contact_id = token_check[:valid] ? token_check.dig(:payload, :contact_id) : nil
    @verified_contact = contact_id.present? ? account.contacts.find_by(id: contact_id) : nil
  end

  def handle_back_action
    selection = back_selection_params
    return handle_booking_step_submit(**selection) if payload[:screen].to_s == 'DETAILS_STEP' && data[:selected_date].present?

    build_booking_step(selection)
  end

  def back_selection_params
    {
      service_id: data[:selected_service_id] || data[:service_id],
      resource_id: data[:selected_resource_id] || data[:resource_id],
      booking_date: data[:selected_date] || data[:booking_date]
    }
  end

  def handle_data_exchange
    case data[:step].to_s
    when 'BOOKING_STEP'
      handle_booking_step_submit(
        service_id: data[:service_id],
        resource_id: data[:resource_id],
        booking_date: data[:booking_date]
      )
    when 'SLOT_STEP'
      handle_slot_step_submit
    when 'CONFIRM_BOOKING'
      handle_confirm_booking
    else
      build_booking_step
    end
  end

  def handle_booking_step_submit(service_id:, resource_id:, booking_date:)
    service = resolver.find_service(service_id)
    resources = resolver.candidate_resources(resource_id, service: service)
    if resources.empty?
      return build_booking_step(
        service_id: service_id, resource_id: resource_id, booking_date: booking_date,
        error: copy[:no_specialists_error]
      )
    end

    date = resolver.parse_booking_date(booking_date)
    slots = resolver.slots_for_date(resources: resources, date: date, service: service)
    return handle_empty_slots_on_date(service, resource_id, resources, date) if slots.empty?

    build_slot_step(service: service, resource_id: resource_id, resources: resources, date: date, slots: slots)
  end

  def handle_empty_slots_on_date(service, resource_id, resources, date)
    next_date = resolver.nearest_available_date(resources: resources, after_date: date, service: service)
    if next_date
      msg = format(
        copy[:no_slots_on_date_with_next],
        date: format_date(date),
        next_date: format_date(next_date)
      )
      return build_booking_step(
        service_id: service&.id, resource_id: resource_id, booking_date: next_date.iso8601, error: msg
      )
    end

    build_booking_step(
      service_id: service&.id, resource_id: resource_id, booking_date: date.iso8601,
      error: copy[:no_slots_any_date]
    )
  end

  def handle_slot_step_submit
    service = resolver.find_service(data[:service_id])
    slot = resolver.resolve_slot_key(data[:slot_key], service: service)
    return slot_step_error_fallback(service) if slot.nil?

    build_details_step(service: service, slot: slot)
  end

  def slot_step_error_fallback(service)
    resources = resolver.candidate_resources(data[:resource_id], service: service)
    date = resolver.parse_booking_date(data[:booking_date])
    slots = resolver.slots_for_date(resources: resources, date: date, service: service)
    error = data[:slot_key].blank? ? copy[:slot_required_error] : copy[:slot_taken_error]
    build_slot_step(
      service: service, resource_id: data[:resource_id], resources: resources,
      date: date, slots: slots, error: error
    )
  end

  def handle_confirm_booking
    service = resolver.find_service(data[:service_id])
    slot = resolver.resolve_slot_key(data[:slot_key], service: service)
    return confirm_slot_taken_fallback(service) if slot.nil?

    validation = client_validator_for(slot[:resource]).validate_submission(data)
    return build_details_step(service: service, slot: slot, submitted: data, error: validation[:error]) unless validation[:valid]

    build_success_response(service: service, slot: slot, client_attrs: validation[:attributes])
  end

  def confirm_slot_taken_fallback(service)
    fallback_resource = resolver.candidate_resources(data[:resource_id], service: service).first
    build_details_step(
      service: service,
      slot: unavailable_slot_stub(fallback_resource),
      submitted: data,
      error: copy[:slot_taken_error]
    )
  end

  def build_booking_step(overrides = {})
    opts = overrides.to_h.with_indifferent_access
    options = booking_step_dropdown_options
    error_text = opts[:error].presence || (resolver.available_resources.empty? ? copy[:no_specialists_error] : '')

    {
      screen: 'BOOKING_STEP',
      data: booking_step_payload_data(options, opts, error_text)
    }
  end

  def booking_step_dropdown_options
    {
      services: build_service_options(resolver.active_services),
      specialists: build_specialist_options(resolver.available_resources),
      dates: resolver.upcoming_dates.map { |d| { id: d.iso8601, title: format_date(d).truncate(TITLE_LIMIT) } }
    }
  end

  def booking_step_payload_data(options, opts, error_text)
    {
      has_error: error_text.present?,
      error_message: error_text.to_s,
      show_services: resolver.active_services.any?,
      services: options[:services],
      specialists: options[:specialists],
      dates: options[:dates],
      init_service_id: resolve_option_id(options[:services], opts[:service_id]),
      init_resource_id: resolve_option_id(options[:specialists], opts[:resource_id]),
      init_booking_date: resolve_option_id(options[:dates], opts[:booking_date])
    }
  end

  # rubocop:disable Metrics/ParameterLists
  def build_slot_step(service:, resource_id:, resources:, date:, slots:, error: nil)
    slot_options = build_slot_dropdown_options(slots, service, resources.size > 1)
    chosen_resource_label = resources.one? ? resources.first.name : copy[:any_specialist]
    summary = [service&.name, chosen_resource_label, format_date(date)].compact_blank.join(' • ').truncate(80)

    {
      screen: 'SLOT_STEP',
      data: {
        selection_summary: summary, has_error: error.present?, error_message: error.to_s,
        slots: slot_options, selected_service_id: service ? service.id.to_s : 'none',
        selected_resource_id: resource_id.presence.to_s.presence || 'any', selected_date: date.iso8601
      }
    }
  end
  # rubocop:enable Metrics/ParameterLists

  def build_slot_dropdown_options(slots, service, show_resource_name)
    return [{ id: 'none', title: '-', description: '' }] if slots.empty?

    slots.map { |entry| format_slot_option(entry, service, show_resource_name) }
  end

  def build_details_step(service:, slot:, submitted: {}, error: nil)
    resource = slot[:resource]
    validator = client_validator_for(resource)
    base_data = details_step_base_data(service, resource, slot, error)

    {
      screen: 'DETAILS_STEP',
      data: base_data.merge(validator.field_flags).merge(validator.prefill_values(submitted))
    }
  end

  def details_step_base_data(service, resource, slot, error)
    local_start = slot[:local_start]
    {
      booking_summary: details_booking_summary(service, resource, local_start),
      has_error: error.present?,
      error_message: error.to_s,
      selected_service_id: service ? service.id.to_s : 'none',
      selected_resource_id: (resource&.id || data[:resource_id]).to_s,
      selected_date: local_start ? local_start.to_date.iso8601 : data[:booking_date].to_s,
      selected_slot_key: (slot[:key].presence || data[:slot_key]).to_s
    }
  end

  def details_booking_summary(service, resource, local_start)
    time_text = local_start ? "#{format_date(local_start.to_date)}, #{local_start.strftime('%H:%M')}" : data[:booking_date].to_s
    [service&.name, resource&.name, time_text].compact_blank.join(' • ').truncate(80)
  end

  def build_success_response(service:, slot:, client_attrs:)
    params = build_completion_params(service, slot).merge(client_attrs).compact_blank
    {
      screen: 'SUCCESS',
      data: { extension_message_response: { params: params } }
    }
  end

  def build_completion_params(service, slot)
    resource = slot[:resource]
    {
      flow_token: payload[:flow_token].to_s.presence || 'unused',
      booking_grant: build_booking_grant(service, slot),
      onelink_flow_kind: 'booking',
      resource_id: resource.id.to_s,
      resource_name: resource.name,
      service_id: service&.id&.to_s,
      service_name: service&.name,
      starts_at: slot[:starts_at].iso8601,
      duration_min: slot[:duration_min],
      booking_date: slot[:local_start].to_date.iso8601,
      slot_label: "#{slot[:local_start].strftime('%d.%m.%Y %H:%M')}–#{slot[:local_end].strftime('%H:%M')}",
      medelement_cabinet_code: slot[:cabinet_code]
    }
  end

  def build_booking_grant(service, slot)
    return nil unless token_check[:valid]

    Whatsapp::Flows::TokenService.generate_booking_grant(
      channel: channel,
      conversation_id: token_check.dig(:payload, :conversation_id),
      contact_id: token_check.dig(:payload, :contact_id),
      resource_id: slot[:resource].id,
      service_id: service&.id,
      starts_at: slot[:starts_at].iso8601,
      duration_min: slot[:duration_min],
      cabinet_code: slot[:cabinet_code]
    )
  end

  def build_service_options(services)
    return [{ id: 'none', title: '-', description: '' }] if services.empty?

    services.map do |svc|
      full_name = svc.name.to_s.strip
      duration_label = svc.duration_min.present? ? "#{svc.duration_min} #{copy[:duration_min_short]}" : ''
      desc = full_name.length > TITLE_LIMIT ? [full_name, duration_label].compact_blank.join(' • ') : duration_label
      { id: svc.id.to_s, title: full_name.truncate(TITLE_LIMIT), description: desc.truncate(DESCRIPTION_LIMIT) }
    end
  end

  def build_specialist_options(resources)
    return [{ id: 'none', title: '-', description: '' }] if resources.empty?

    options = resources.map do |res|
      full_name = res.name.to_s.strip
      specialty = res.custom_attributes.to_h['specialty'].to_s.strip
      desc = full_name.length > TITLE_LIMIT ? [full_name, specialty].compact_blank.join(' • ') : specialty
      { id: res.id.to_s, title: full_name.truncate(TITLE_LIMIT), description: desc.truncate(DESCRIPTION_LIMIT) }
    end
    options.unshift(id: 'any', title: copy[:any_specialist].truncate(TITLE_LIMIT), description: '') if resources.size > 1
    options
  end

  def format_slot_option(entry, service, show_resource_name)
    time_range = "#{entry[:local_start].strftime('%H:%M')} – #{entry[:local_end].strftime('%H:%M')}"
    desc = show_resource_name ? entry[:resource].name.to_s : service&.name.to_s
    { id: entry[:key], title: time_range.truncate(TITLE_LIMIT), description: desc.to_s.truncate(DESCRIPTION_LIMIT) }
  end

  def resolve_option_id(options, preferred)
    target = preferred.to_s
    return target if target.present? && options.any? { |opt| opt[:id] == target }

    options.first[:id]
  end

  def unavailable_slot_stub(resource)
    { key: data[:slot_key].to_s, resource: resource, local_start: nil }
  end

  def client_validator_for(resource)
    Whatsapp::Flows::BookingClientValidator.new(
      account: account, resource: resource, locale: locale, contact: verified_contact
    )
  end

  def format_date(date)
    Whatsapp::Flows::BookingFlowCopy.format_date(date, locale: locale)
  end
end
