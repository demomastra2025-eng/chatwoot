# frozen_string_literal: true

class Whatsapp::Flows::BookingFlowSchemaBuilder # rubocop:disable Metrics/ClassLength
  FLOW_JSON_VERSION = '6.0'
  DATA_API_VERSION = '3.0'
  FIELD_LABEL_LIMIT = 20
  FOOTER_LABEL_LIMIT = 35

  def initialize(locale: nil, account: nil, specialist_label: nil, service_label: nil, confirm_cta: nil)
    @locale = Whatsapp::Flows::BookingFlowCopy.normalize_locale(locale, account: account)
    @copy = Whatsapp::Flows::BookingFlowCopy.for_locale(@locale)
    @specialist_label = specialist_label.to_s.strip.presence || @copy[:specialist_label]
    @service_label = service_label.to_s.strip.presence || @copy[:service_label]
    @confirm_cta = confirm_cta.to_s.strip.presence || @copy[:confirm_cta]
    validate_custom_labels!
  end

  def build
    {
      version: FLOW_JSON_VERSION,
      data_api_version: DATA_API_VERSION,
      routing_model: {
        'BOOKING_STEP' => ['SLOT_STEP'],
        'SLOT_STEP' => ['DETAILS_STEP'],
        'DETAILS_STEP' => []
      },
      screens: [booking_step_screen, slot_step_screen, details_step_screen]
    }
  end

  def to_json(*_args)
    JSON.pretty_generate(build)
  end

  private

  attr_reader :copy, :specialist_label, :service_label, :confirm_cta

  def validate_custom_labels!
    raise ArgumentError, "Specialist label cannot exceed #{FIELD_LABEL_LIMIT} characters" if specialist_label.length > FIELD_LABEL_LIMIT
    raise ArgumentError, "Service label cannot exceed #{FIELD_LABEL_LIMIT} characters" if service_label.length > FIELD_LABEL_LIMIT
    raise ArgumentError, "Confirm button label cannot exceed #{FOOTER_LABEL_LIMIT} characters" if confirm_cta.length > FOOTER_LABEL_LIMIT
  end

  def booking_step_screen
    {
      id: 'BOOKING_STEP',
      title: copy[:booking_screen_title],
      terminal: false,
      data: booking_step_data_schema,
      layout: {
        type: 'SingleColumnLayout',
        children: [error_banner_component, booking_step_form]
      }
    }
  end

  def booking_step_form
    {
      'type' => 'Form',
      'name' => 'booking_step_form',
      'init-values' => {
        service_id: '${data.init_service_id}',
        resource_id: '${data.init_resource_id}',
        booking_date: '${data.init_booking_date}'
      },
      'children' => booking_form_children
    }
  end

  def booking_form_children
    [
      dropdown_field(
        name: 'service_id', label: service_label, source: '${data.services}',
        required: '${data.show_services}', visible: '${data.show_services}'
      ),
      dropdown_field(name: 'resource_id', label: specialist_label, source: '${data.specialists}'),
      dropdown_field(name: 'booking_date', label: copy[:date_label], source: '${data.dates}'),
      footer_component(copy[:choose_time_cta], booking_submit_payload)
    ]
  end

  def booking_submit_payload
    {
      step: 'BOOKING_STEP',
      service_id: '${form.service_id}',
      resource_id: '${form.resource_id}',
      booking_date: '${form.booking_date}'
    }
  end

  def slot_step_screen
    {
      id: 'SLOT_STEP',
      title: copy[:slot_screen_title],
      terminal: false,
      data: slot_step_data_schema,
      layout: {
        type: 'SingleColumnLayout',
        children: [subheading_component('${data.selection_summary}'), error_banner_component, slot_step_form]
      }
    }
  end

  def slot_step_form
    {
      type: 'Form',
      name: 'slot_step_form',
      children: [
        dropdown_field(name: 'slot_key', label: copy[:slot_label], source: '${data.slots}'),
        footer_component(copy[:next_cta], slot_submit_payload)
      ]
    }
  end

  def slot_submit_payload
    {
      step: 'SLOT_STEP',
      service_id: '${data.selected_service_id}',
      resource_id: '${data.selected_resource_id}',
      booking_date: '${data.selected_date}',
      slot_key: '${form.slot_key}'
    }
  end

  def details_step_screen
    {
      id: 'DETAILS_STEP',
      title: copy[:details_screen_title],
      terminal: true,
      success: true,
      data: details_step_data_schema,
      layout: {
        type: 'SingleColumnLayout',
        children: [subheading_component('${data.booking_summary}'), error_banner_component, details_step_form]
      }
    }
  end

  def details_step_form
    {
      'type' => 'Form',
      'name' => 'details_step_form',
      'init-values' => details_form_init_values,
      'children' => details_form_children
    }
  end

  def details_form_init_values
    {
      client_first_name: '${data.init_first_name}',
      client_last_name: '${data.init_last_name}',
      client_middle_name: '${data.init_middle_name}',
      client_phone: '${data.init_phone}',
      client_birth_date: '${data.init_birth_date}',
      client_iin: '${data.init_iin}',
      notes: '${data.init_notes}'
    }
  end

  def details_form_children
    [
      text_input_field(name: 'client_first_name', label: copy[:first_name_label], required: true),
      text_input_field(
        name: 'client_last_name', label: copy[:last_name_label],
        visible: '${data.show_last_name}', required: '${data.require_last_name}'
      ),
      text_input_field(
        name: 'client_middle_name', label: copy[:middle_name_label],
        visible: '${data.show_middle_name}', required: '${data.require_middle_name}'
      ),
      text_input_field(name: 'client_phone', label: copy[:phone_label], required: true, input_type: 'phone', max_chars: 24),
      *optional_identity_fields,
      notes_field,
      footer_component(confirm_cta, details_submit_payload)
    ]
  end

  def optional_identity_fields
    [
      text_input_field(
        name: 'client_birth_date', label: copy[:birth_date_label], helper_text: copy[:birth_date_helper],
        visible: '${data.show_birth_date}', required: '${data.require_birth_date}', max_chars: 10
      ),
      text_input_field(
        name: 'client_iin', label: copy[:iin_label], helper_text: copy[:iin_helper],
        visible: '${data.show_iin}', required: '${data.require_iin}', max_chars: 12
      )
    ]
  end

  def notes_field
    { 'type' => 'TextArea', 'name' => 'notes', 'label' => copy[:notes_label], 'required' => false, 'max-length' => 300 }
  end

  def details_submit_payload
    {
      step: 'CONFIRM_BOOKING',
      service_id: '${data.selected_service_id}',
      resource_id: '${data.selected_resource_id}',
      booking_date: '${data.selected_date}',
      slot_key: '${data.selected_slot_key}',
      client_first_name: '${form.client_first_name}',
      client_last_name: '${form.client_last_name}',
      client_middle_name: '${form.client_middle_name}',
      client_phone: '${form.client_phone}',
      client_birth_date: '${form.client_birth_date}',
      client_iin: '${form.client_iin}',
      notes: '${form.notes}'
    }
  end

  def dropdown_field(name:, label:, source:, required: true, visible: nil)
    field = { 'type' => 'Dropdown', 'name' => name, 'label' => label, 'required' => required, 'data-source' => source }
    field['visible'] = visible if visible.present?
    field
  end

  # rubocop:disable Metrics/ParameterLists
  def text_input_field(name:, label:, required:, input_type: 'text', max_chars: 80, visible: nil, helper_text: nil)
    field = {
      'type' => 'TextInput', 'name' => name, 'input-type' => input_type,
      'label' => label, 'required' => required, 'max-chars' => max_chars
    }
    field['helper-text'] = helper_text if helper_text.present?
    field['visible'] = visible if visible.present?
    field
  end
  # rubocop:enable Metrics/ParameterLists

  def footer_component(label, action_payload)
    { 'type' => 'Footer', 'label' => label, 'on-click-action' => { name: 'data_exchange', payload: action_payload } }
  end

  def subheading_component(text)
    { type: 'TextSubheading', text: text }
  end

  def error_banner_component
    { type: 'TextBody', text: '${data.error_message}', visible: '${data.has_error}' }
  end

  def booking_step_data_schema
    {
      has_error: boolean_example(false),
      error_message: string_example(''),
      show_services: boolean_example(true),
      services: option_list_schema(with_description: true, example_title: service_label),
      specialists: option_list_schema(with_description: true, example_title: specialist_label),
      dates: option_list_schema(with_description: false, example_id: '2026-10-30', example_title: '30.10'),
      init_service_id: string_example('1'),
      init_resource_id: string_example('any'),
      init_booking_date: string_example('2026-10-30')
    }
  end

  def slot_step_data_schema
    {
      selection_summary: string_example("#{specialist_label} • 30.10"),
      has_error: boolean_example(false),
      error_message: string_example(''),
      slots: option_list_schema(with_description: true, example_id: '1@2026-10-30T10:00:00+05:00', example_title: '10:00 – 10:30'),
      selected_service_id: string_example('1'),
      selected_resource_id: string_example('1'),
      selected_date: string_example('2026-10-30')
    }
  end

  def details_step_data_schema
    details_selection_data_schema.merge(details_flags_data_schema).merge(details_init_data_schema)
  end

  def details_selection_data_schema
    {
      booking_summary: string_example('30.10, 10:00'),
      has_error: boolean_example(false),
      error_message: string_example(''),
      selected_service_id: string_example('1'),
      selected_resource_id: string_example('1'),
      selected_date: string_example('2026-10-30'),
      selected_slot_key: string_example('1@2026-10-30T10:00:00+05:00')
    }
  end

  def details_flags_data_schema
    {
      show_last_name: boolean_example(true),
      require_last_name: boolean_example(false),
      show_middle_name: boolean_example(false),
      require_middle_name: boolean_example(false),
      show_birth_date: boolean_example(false),
      require_birth_date: boolean_example(false),
      show_iin: boolean_example(false),
      require_iin: boolean_example(false)
    }
  end

  def details_init_data_schema
    {
      init_first_name: string_example(''),
      init_last_name: string_example(''),
      init_middle_name: string_example(''),
      init_phone: string_example('+77001234567'),
      init_birth_date: string_example(''),
      init_iin: string_example(''),
      init_notes: string_example('')
    }
  end

  def option_list_schema(with_description:, example_title:, example_id: '1')
    properties = { id: { type: 'string' }, title: { type: 'string' } }
    example = { id: example_id, title: example_title }
    if with_description
      properties[:description] = { type: 'string' }
      example[:description] = ''
    end
    { type: 'array', items: { type: 'object', properties: properties }, __example__: [example] }
  end

  def string_example(value) = { type: 'string', __example__: value }
  def boolean_example(value) = { type: 'boolean', __example__: value }
end
