require 'rails_helper'

RSpec.describe 'Scheduling Appointments API', type: :request do
  let(:account) { create(:account) }
  let!(:work_rule) do
    create(:scheduling_work_rule, resource: resource, account: account, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)
  end
  let(:base_params) do
    {
      resource_id: resource.id,
      contact_id: contact.id,
      service_id: service.id,
      starts_at: booking_day.iso8601,
      ends_at: (booking_day + 30.minutes).iso8601,
      client_name: 'Test Patient',
      client_phone: '+77015554433',
      service_amount: 20_000
    }
  end
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:resource) { create(:scheduling_resource, account: account, timezone: 'Asia/Almaty') }
  let(:service) { create(:scheduling_service, account: account, base_price: 20_000) }
  let(:contact) { create(:contact, account: account, name: 'Test Patient', phone_number: '+77015554433') }
  let(:headers) { agent.create_new_auth_token }
  let(:booking_day) { ActiveSupport::TimeZone['Asia/Almaty'].local(2026, 3, 9, 10, 0, 0) }
  let(:path) { "/api/v1/accounts/#{account.id}/scheduling/appointments" }

  before do
    account.enable_features!('scheduling', 'scheduling_finance')
  end

  def response_body
    response.parsed_body
  end

  it 'creates an appointment inside a valid slot' do
    post path, params: base_params, headers: headers, as: :json

    expect(response).to have_http_status(:created)
    expect(response_body.dig('payload', 'resource_id')).to eq(resource.id)
    expect(response_body.dig('payload', 'service_id')).to eq(service.id)
  end

  it 'applies default values from managed appointment custom fields' do
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'appointment',
      key: 'visit_reason',
      label: 'Visit reason',
      field_type: 'text',
      default_value: 'initial consult'
    )

    post path, params: base_params, headers: headers, as: :json

    expect(response).to have_http_status(:created)
    expect(response_body.dig('payload', 'custom_attributes')).to include(
      {
        'visit_reason' => 'initial consult'
      }
    )
    expect(response_body.dig('payload', 'custom_attributes', 'service_ids')).to include(service.id)
  end

  it 'accepts booking intake appointment fields in the standard scheduling create flow' do
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'appointment',
      key: 'triage_note',
      label: 'Triage note',
      field_type: 'text',
      rules: { contexts: ['booking_intake'] }
    )

    post path,
         params: base_params.merge(custom_attributes: { triage_note: 'Needs translator' }),
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response_body.dig('payload', 'custom_attributes')).to include(
      {
        'triage_note' => 'Needs translator'
      }
    )
    expect(response_body.dig('payload', 'custom_attributes', 'service_ids')).to include(service.id)
  end

  it 'rejects unknown appointment custom fields when managed definitions exist' do
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'appointment',
      key: 'visit_reason',
      label: 'Visit reason',
      field_type: 'text'
    )

    post path,
         params: base_params.merge(custom_attributes: { unknown_key: 'raw value' }),
         headers: headers,
         as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body['code']).to eq('VALIDATION_ERROR')
    expect(response_body.dig('details', 'custom_attributes.unknown_key')).to include('is not a known active field')
  end

  it 'creates an appointment with prepayment and defaults the payment method' do
    post path,
         params: base_params.merge(prepaid_amount: 5_000),
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response_body.dig('payload', 'prepaid_amount')).to eq(5_000)
    expect(response_body.dig('payload', 'prepaid_payment_method')).to eq('cash')
    expect(response_body.dig('payload', 'payment_status')).to eq('prepaid')

    appointment = Scheduling::Appointment.find(response_body.dig('payload', 'id'))
    prepaid_payment = appointment.payments.find_by(payment_kind: 'prepaid')

    expect(prepaid_payment).to be_present
    expect(prepaid_payment.payment_method).to eq('cash')
    expect(prepaid_payment.amount).to eq(5_000)
  end

  it 'normalizes decimal zero money amounts when creating an appointment' do
    post path,
         params: base_params.merge(service_amount: '20000.0', prepaid_amount: '5000.00'),
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response_body.dig('payload', 'service_amount')).to eq(20_000)
    expect(response_body.dig('payload', 'prepaid_amount')).to eq(5_000)
  end

  it 'rejects fractional money amounts when creating an appointment' do
    post path,
         params: base_params.merge(service_amount: '20000.50'),
         headers: headers,
         as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body['error']).to eq('service_amount must be an integer')
  end

  it 'merges custom attributes when updating an appointment' do
    appointment = create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      contact: contact,
      service: service,
      service_amount: 20_000,
      starts_at: booking_day,
      ends_at: booking_day + 30.minutes,
      custom_attributes: { existing_key: 'existing value' }
    )

    put "#{path}/#{appointment.id}",
        params: {
          custom_attributes: { new_key: 'new value' }
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body.dig('payload', 'custom_attributes')).to include(
      {
        'existing_key' => 'existing value',
        'new_key' => 'new value'
      }
    )
    expect(response_body.dig('payload', 'custom_attributes', 'service_ids')).to include(service.id)
    expect(appointment.reload.custom_attributes).to eq(response_body.dig('payload', 'custom_attributes'))
  end

  it 'preserves existing system appointment custom attributes while updating managed ones' do
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'appointment',
      key: 'visit_reason',
      label: 'Visit reason',
      field_type: 'text'
    )
    appointment = create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      contact: contact,
      service: service,
      service_amount: 20_000,
      starts_at: booking_day,
      ends_at: booking_day + 30.minutes,
      custom_attributes: { medelement_reception_code: '42' }
    )

    put "#{path}/#{appointment.id}",
        params: {
          custom_attributes: { visit_reason: 'follow up' }
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body.dig('payload', 'custom_attributes')).to include(
      {
        'medelement_reception_code' => '42',
        'visit_reason' => 'follow up'
      }
    )
    expect(response_body.dig('payload', 'custom_attributes', 'service_ids')).to include(service.id)
    expect(appointment.reload.custom_attributes).to eq(response_body.dig('payload', 'custom_attributes'))
  end

  it 'preserves existing unmanaged appointment custom attributes while updating managed ones' do
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'appointment',
      key: 'visit_reason',
      label: 'Visit reason',
      field_type: 'text'
    )
    appointment = create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      contact: contact,
      service: service,
      service_amount: 20_000,
      starts_at: booking_day,
      ends_at: booking_day + 30.minutes,
      custom_attributes: {
        'legacy_key' => 'legacy value',
        'visit_reason' => 'follow up'
      }
    )

    put "#{path}/#{appointment.id}",
        params: {
          custom_attributes: { visit_reason: 'initial consult' }
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body.dig('payload', 'custom_attributes')).to include(
      {
        'legacy_key' => 'legacy value',
        'visit_reason' => 'initial consult'
      }
    )
    expect(response_body.dig('payload', 'custom_attributes', 'service_ids')).to include(service.id)
    expect(appointment.reload.custom_attributes).to eq(response_body.dig('payload', 'custom_attributes'))
  end

  it 'drops deleted managed appointment field values on the next update' do
    field_definition = create(
      :crm_field_definition,
      account: account,
      entity_kind: 'appointment',
      key: 'visit_reason',
      label: 'Visit reason',
      field_type: 'text'
    )
    appointment = create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      contact: contact,
      service: service,
      service_amount: 20_000,
      starts_at: booking_day,
      ends_at: booking_day + 30.minutes,
      custom_attributes: {
        'visit_reason' => 'follow up',
        'medelement_reception_code' => '42'
      }
    )

    field_definition.class.transaction do
      field_definition.destroy!
      Crm::FieldDefinitionValueCleanupService.new(
        account: account,
        entity_kind: 'appointment',
        key: 'visit_reason'
      ).perform
    end

    put "#{path}/#{appointment.id}",
        params: {
          client_comment: 'Updated note'
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body.dig('payload', 'custom_attributes')).to include(
      {
        'medelement_reception_code' => '42'
      }
    )
    expect(response_body.dig('payload', 'custom_attributes')).not_to have_key('visit_reason')
    expect(response_body.dig('payload', 'custom_attributes', 'service_ids')).to include(service.id)
    expect(appointment.reload.custom_attributes).to eq(response_body.dig('payload', 'custom_attributes'))
  end

  it 'rejects appointment outside working hours' do
    post path, params: base_params.merge(starts_at: booking_day.change(hour: 8).iso8601, ends_at: booking_day.change(hour: 8, min: 30).iso8601),
               headers: headers, as: :json

    expect(response).to have_http_status(:conflict)
    expect(response_body['code']).to eq('OUTSIDE_WORKING_HOURS')
  end

  it 'rejects holiday conflicts' do
    create(:scheduling_holiday, account: account, date: booking_day.to_date)

    post path, params: base_params, headers: headers, as: :json

    expect(response).to have_http_status(:conflict)
    expect(response_body['code']).to eq('BLOCKED_BY_HOLIDAY')
  end

  it 'rejects break conflicts' do
    create(:scheduling_break_rule, resource: resource, account: account, weekday: 1, start_minute: 10 * 60, end_minute: 11 * 60)

    post path, params: base_params, headers: headers, as: :json

    expect(response).to have_http_status(:conflict)
    expect(response_body['code']).to eq('BLOCKED_BY_BREAK')
  end

  it 'rejects time off conflicts' do
    create(:scheduling_time_off, resource: resource, account: account, starts_at: booking_day, ends_at: booking_day + 2.hours)

    post path, params: base_params, headers: headers, as: :json

    expect(response).to have_http_status(:conflict)
    expect(response_body['code']).to eq('BLOCKED_BY_VACATION')
  end

  it 'rejects appointment overlap conflicts' do
    create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      contact: contact,
      service: service,
      starts_at: booking_day,
      ends_at: booking_day + 1.hour
    )

    post path, params: base_params, headers: headers, as: :json

    expect(response).to have_http_status(:conflict)
    expect(response_body['code']).to eq('SLOT_CONFLICT')
  end

  it 'rejects inactive service-resource combinations' do
    service.update!(active: false)

    post path, params: base_params, headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body['code']).to eq('SERVICE_NOT_AVAILABLE_FOR_RESOURCE')
  end

  it 'replays idempotent create requests with status 200' do
    params = base_params.merge(idempotency_key: 'idem-1')

    post path, params: params, headers: headers, as: :json
    created_id = response_body.dig('payload', 'id')

    post path, params: params, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body.dig('payload', 'id')).to eq(created_id)
    expect(account.scheduling_appointments.where(idempotency_key: 'idem-1').count).to eq(1)
  end

  it 'rejects duplicate external_ref values' do
    create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      contact: contact,
      service: service,
      external_ref: 'ext-1'
    )

    post path, params: base_params.merge(external_ref: 'ext-1'), headers: headers, as: :json

    expect(response).to have_http_status(:conflict)
    expect(response_body['code']).to eq('DUPLICATE_EXTERNAL_REF')
  end

  it 'rejects invalid IIN values in appointment payloads' do
    post path, params: base_params.merge(client_identifier: '123456789012'), headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body['code']).to eq('INVALID_IIN')
  end

  it 'updates a no-service appointment when moving it in the calendar' do
    appointment = create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      contact: contact,
      service: nil,
      client_name: 'Walk-in patient',
      client_phone: '+77015554433',
      service_amount: 0,
      starts_at: booking_day,
      ends_at: booking_day + 30.minutes
    )

    put "#{path}/#{appointment.id}",
        params: {
          starts_at: (booking_day + 1.hour).iso8601,
          ends_at: (booking_day + 90.minutes).iso8601
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body.dig('payload', 'service_id')).to be_nil
    expect(response_body.dig('payload', 'service_amount')).to eq(0)
    expect(Time.iso8601(response_body.dig('payload', 'starts_at'))).to eq(booking_day + 1.hour)
    expect(Time.iso8601(response_body.dig('payload', 'ends_at'))).to eq(booking_day + 90.minutes)
  end

  it 'keeps the saved service amount when updating an appointment without changing service or specialist' do
    create(
      :scheduling_service_price,
      account: account,
      service: service,
      resource: resource,
      price: 20_000
    )
    appointment = create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      contact: contact,
      service: service,
      service_amount: 20_000,
      starts_at: booking_day,
      ends_at: booking_day + 30.minutes
    )

    service.prices.find_by!(resource_id: resource.id).update!(price: 30_000)

    put "#{path}/#{appointment.id}",
        params: {
          starts_at: (booking_day + 1.hour).iso8601,
          ends_at: (booking_day + 90.minutes).iso8601
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body.dig('payload', 'service_amount')).to eq(20_000)
    expect(appointment.reload.service_amount).to eq(20_000)
  end

  it 'keeps a zero service amount when updating an appointment without changing service or specialist' do
    create(
      :scheduling_service_price,
      account: account,
      service: service,
      resource: resource,
      price: 20_000
    )
    appointment = create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      contact: contact,
      service: service,
      service_amount: 0,
      starts_at: booking_day,
      ends_at: booking_day + 30.minutes
    )

    service.prices.find_by!(resource_id: resource.id).update!(price: 30_000)

    put "#{path}/#{appointment.id}",
        params: {
          starts_at: (booking_day + 1.hour).iso8601,
          ends_at: (booking_day + 90.minutes).iso8601
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body.dig('payload', 'service_amount')).to eq(0)
    expect(appointment.reload.service_amount).to eq(0)
  end

  it 'clears prepaid payment method and prepaid journal entry when prepayment is removed' do
    appointment = create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      contact: contact,
      service: service,
      prepaid_amount: 5_000,
      prepaid_payment_method: 'kaspi_qr',
      payment_status: 'prepaid',
      starts_at: booking_day,
      ends_at: booking_day + 30.minutes
    )
    create(
      :scheduling_payment,
      appointment: appointment,
      account: account,
      amount: 5_000,
      payment_method: 'kaspi_qr',
      payment_kind: 'prepaid'
    )

    put "#{path}/#{appointment.id}",
        params: { prepaid_amount: 0 },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body.dig('payload', 'prepaid_amount')).to eq(0)
    expect(response_body.dig('payload', 'prepaid_payment_method')).to be_nil
    expect(response_body.dig('payload', 'payment_status')).to eq('awaiting_payment')

    appointment.reload

    expect(appointment.prepaid_payment_method).to be_nil
    expect(appointment.payments.find_by(payment_kind: 'prepaid')).to be_nil
  end

  it 'rejects updates to imported Medelement appointments' do
    appointment = create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      contact: contact,
      service: service,
      source: 'medelement',
      external_ref: 'medelement:reception:1'
    )

    put "#{path}/#{appointment.id}",
        params: { client_name: 'Changed patient' },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body['code']).to eq('APPOINTMENT_READ_ONLY')
  end

  it 'returns a stable calendar payload shape' do
    appointment = create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      contact: contact,
      service: service,
      starts_at: booking_day,
      ends_at: booking_day + 30.minutes,
      payment_status: 'paid',
      settlement_amount: 20_000,
      settlement_payment_method: 'cash'
    )
    create(:scheduling_holiday, account: account, date: booking_day.to_date + 1.day)
    create(:scheduling_workday_override, resource: resource, account: account, date: booking_day.to_date + 2.days)
    create(:scheduling_time_off, resource: resource, account: account, starts_at: booking_day + 3.days, ends_at: booking_day + 3.days + 2.hours)
    create(:scheduling_payment, appointment: appointment, account: account, amount: 20_000, payment_method: 'cash', payment_kind: 'payment')
    create(:scheduling_expense, appointment: appointment, account: account, resource: resource, amount: 8_000)

    get "/api/v1/accounts/#{account.id}/scheduling/calendar",
        params: {
          view: 'week',
          from: booking_day.beginning_of_day.iso8601,
          to: (booking_day + 7.days).end_of_day.iso8601,
          include_slots: true
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body['payload'].keys).to include(
      'resources', 'work_rules', 'break_rules', 'holidays', 'workday_overrides',
      'time_offs', 'appointments', 'payments', 'expenses', 'slots'
    )
  end

  it 'filters the calendar payload by managed appointment custom fields' do
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'appointment',
      key: 'visit_reason',
      label: 'Visit reason',
      field_type: 'select',
      options: [{ 'label' => 'Follow-up', 'value' => 'follow_up' }]
    )
    matching_appointment = create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      contact: contact,
      service: service,
      starts_at: booking_day,
      ends_at: booking_day + 30.minutes,
      custom_attributes: { 'visit_reason' => 'follow_up' }
    )
    create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      contact: contact,
      service: service,
      starts_at: booking_day + 1.hour,
      ends_at: booking_day + 90.minutes,
      custom_attributes: { 'visit_reason' => 'initial' }
    )

    get "/api/v1/accounts/#{account.id}/scheduling/calendar",
        params: {
          view: 'week',
          from: booking_day.beginning_of_day.iso8601,
          to: (booking_day + 7.days).end_of_day.iso8601,
          custom_attribute_filters: {
            visit_reason: ['follow_up']
          }
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body.dig('payload', 'appointments').pluck('id')).to eq([matching_appointment.id])
  end

  it 'keeps non-matching appointments as slot blockers in the calendar availability payload' do
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'appointment',
      key: 'visit_reason',
      label: 'Visit reason',
      field_type: 'select',
      options: [{ 'label' => 'Follow-up', 'value' => 'follow_up' }]
    )
    matching_appointment = create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      contact: contact,
      service: service,
      starts_at: booking_day,
      ends_at: booking_day + 30.minutes,
      custom_attributes: { 'visit_reason' => 'follow_up' }
    )
    blocking_appointment = create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      contact: contact,
      service: service,
      starts_at: booking_day + 1.hour,
      ends_at: booking_day + 90.minutes,
      custom_attributes: { 'visit_reason' => 'initial' }
    )

    get "/api/v1/accounts/#{account.id}/scheduling/calendar",
        params: {
          view: 'week',
          from: booking_day.beginning_of_day.iso8601,
          to: (booking_day + 7.days).end_of_day.iso8601,
          include_slots: true,
          custom_attribute_filters: {
            visit_reason: ['follow_up']
          }
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body.dig('payload', 'appointments').pluck('id')).to eq([matching_appointment.id])
    expect(response_body.dig('payload', 'slots')).not_to include(
      a_hash_including(
        'resource_id' => resource.id,
        'starts_at' => blocking_appointment.starts_at.iso8601,
        'ends_at' => blocking_appointment.ends_at.iso8601
      )
    )
  end

  it 'filters appointments index by managed appointment custom fields' do
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'appointment',
      key: 'needs_lab',
      label: 'Needs lab',
      field_type: 'checkbox'
    )
    matching_appointment = create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      contact: contact,
      service: service,
      starts_at: booking_day,
      ends_at: booking_day + 30.minutes,
      custom_attributes: { 'needs_lab' => true }
    )
    create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      contact: contact,
      service: service,
      starts_at: booking_day + 1.hour,
      ends_at: booking_day + 90.minutes,
      custom_attributes: { 'needs_lab' => false }
    )

    get path,
        params: {
          from: booking_day.beginning_of_day.iso8601,
          to: (booking_day + 1.day).end_of_day.iso8601,
          custom_attribute_filters: {
            needs_lab: [true]
          }
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body.dig('payload').pluck('id')).to eq([matching_appointment.id])
  end

  it 'filters the calendar payload by text appointment custom fields' do
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'appointment',
      key: 'notes',
      label: 'Notes',
      field_type: 'text'
    )
    matching_appointment = create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      contact: contact,
      service: service,
      starts_at: booking_day,
      ends_at: booking_day + 30.minutes,
      custom_attributes: { 'notes' => 'Urgent follow-up after lab' }
    )
    create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      contact: contact,
      service: service,
      starts_at: booking_day + 1.hour,
      ends_at: booking_day + 90.minutes,
      custom_attributes: { 'notes' => 'Routine visit' }
    )

    get "/api/v1/accounts/#{account.id}/scheduling/calendar",
        params: {
          view: 'week',
          from: booking_day.beginning_of_day.iso8601,
          to: (booking_day + 7.days).end_of_day.iso8601,
          custom_attribute_filters: {
            notes: {
              operator: 'contains',
              value: 'follow-up'
            }
          }
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body.dig('payload', 'appointments').pluck('id')).to eq([matching_appointment.id])
  end

  it 'filters appointments index by number appointment custom fields' do
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'appointment',
      key: 'visit_score',
      label: 'Visit score',
      field_type: 'number'
    )
    matching_appointment = create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      contact: contact,
      service: service,
      starts_at: booking_day,
      ends_at: booking_day + 30.minutes,
      custom_attributes: { 'visit_score' => 9 }
    )
    create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      contact: contact,
      service: service,
      starts_at: booking_day + 1.hour,
      ends_at: booking_day + 90.minutes,
      custom_attributes: { 'visit_score' => 4 }
    )

    get path,
        params: {
          from: booking_day.beginning_of_day.iso8601,
          to: (booking_day + 1.day).end_of_day.iso8601,
          custom_attribute_filters: {
            visit_score: {
              operator: 'greater_than',
              value: 5
            }
          }
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body['payload'].pluck('id')).to eq([matching_appointment.id])
  end

  it 'filters appointments index by date appointment custom fields' do
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'appointment',
      key: 'follow_up_on',
      label: 'Follow up on',
      field_type: 'date'
    )
    matching_appointment = create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      contact: contact,
      service: service,
      starts_at: booking_day,
      ends_at: booking_day + 30.minutes,
      custom_attributes: { 'follow_up_on' => '2026-03-10' }
    )
    create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      contact: contact,
      service: service,
      starts_at: booking_day + 1.hour,
      ends_at: booking_day + 90.minutes,
      custom_attributes: { 'follow_up_on' => '2026-03-14' }
    )

    get path,
        params: {
          from: booking_day.beginning_of_day.iso8601,
          to: (booking_day + 7.days).end_of_day.iso8601,
          custom_attribute_filters: {
            follow_up_on: {
              operator: 'before',
              value: '2026-03-11'
            }
          }
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body['payload'].pluck('id')).to eq([matching_appointment.id])
  end

  it 'filters the calendar payload by datetime appointment custom fields' do
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'appointment',
      key: 'triage_at',
      label: 'Triage at',
      field_type: 'datetime'
    )
    matching_appointment = create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      contact: contact,
      service: service,
      starts_at: booking_day,
      ends_at: booking_day + 30.minutes,
      custom_attributes: { 'triage_at' => '2026-03-09T10:15:00+05:00' }
    )
    create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      contact: contact,
      service: service,
      starts_at: booking_day + 1.hour,
      ends_at: booking_day + 90.minutes,
      custom_attributes: { 'triage_at' => '2026-03-09T08:45:00+05:00' }
    )

    get "/api/v1/accounts/#{account.id}/scheduling/calendar",
        params: {
          view: 'week',
          from: booking_day.beginning_of_day.iso8601,
          to: (booking_day + 7.days).end_of_day.iso8601,
          custom_attribute_filters: {
            triage_at: {
              operator: 'after',
              value: '2026-03-09T05:00:00Z'
            }
          }
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body.dig('payload', 'appointments').pluck('id')).to eq([matching_appointment.id])
  end

  it 'deletes a cancelled appointment' do
    appointment = create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      contact: contact,
      service: service,
      starts_at: booking_day,
      ends_at: booking_day + 30.minutes,
      status: 'cancelled',
      payment_status: 'cancelled'
    )

    delete "#{path}/#{appointment.id}",
           headers: headers,
           as: :json

    expect(response).to have_http_status(:no_content)
    expect(Scheduling::Appointment.exists?(appointment.id)).to be(false)
  end

  it 'rejects deleting an appointment before it is cancelled' do
    appointment = create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      contact: contact,
      service: service,
      starts_at: booking_day,
      ends_at: booking_day + 30.minutes,
      status: 'confirmed'
    )

    delete "#{path}/#{appointment.id}",
           headers: headers,
           as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body['code']).to eq('APPOINTMENT_DELETE_REQUIRES_CANCELLED')
    expect(Scheduling::Appointment.exists?(appointment.id)).to be(true)
  end
end
