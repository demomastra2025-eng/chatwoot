require 'rails_helper'

RSpec.describe 'Scheduling Appointments API', type: :request do
  let(:account) { create(:account) }
  let(:work_rule) do
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
  let(:booking_day) do
    timezone = ActiveSupport::TimeZone['Asia/Almaty']
    date = timezone.today.next_occurring(:monday)
    timezone.local(date.year, date.month, date.day, 10, 0, 0)
  end
  let(:path) { "/api/v1/accounts/#{account.id}/scheduling/appointments" }

  before do
    work_rule
    account.enable_features!('scheduling', 'scheduling_finance')
  end

  def response_body
    response.parsed_body
  end

  def stub_medelement_availability
    result = Integrations::Medelement::ResourceAvailabilityService::Result.new(
      status: 'fresh', checked_at: Time.current, slots: [{}], reason: nil
    )
    service = instance_double(Integrations::Medelement::ResourceAvailabilityService, perform: result)
    allow(Integrations::Medelement::ResourceAvailabilityService).to receive(:new).and_return(service)
  end

  it 'creates an appointment inside a valid slot' do
    post path, params: base_params, headers: headers, as: :json

    expect(response).to have_http_status(:created)
    expect(response_body.dig('payload', 'resource_id')).to eq(resource.id)
    expect(response_body.dig('payload', 'resource_name')).to eq(resource.name)
    expect(response_body.dig('payload', 'service_id')).to eq(service.id)
  end

  it 'rejects a Medelement appointment without a patient last name before persistence' do
    resource.update!(custom_attributes: { 'medelement_specialist_code' => 'specialist-1' })
    params = base_params.merge(client_first_name: 'Айжан', client_last_name: '', client_phone: '+77000000001')

    expect do
      post path, params: params, headers: headers, as: :json
    end.not_to change(Scheduling::Appointment, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body['code']).to eq('MEDELEMENT_PATIENT_NAME_INCOMPLETE')
  end

  it 'creates a Medelement appointment without a selected service' do
    stub_medelement_availability
    resource.update!(
      custom_attributes: {
        'medelement_specialist_code' => 'specialist-1',
        'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
      }
    )
    params = base_params.except(:service_id).merge(
      client_first_name: 'Айжан',
      client_last_name: 'Касымова',
      client_phone: '+77000000001',
      custom_attributes: { medelement_cabinet_code: 'cabinet-1' }
    )

    expect do
      post path, params: params, headers: headers, as: :json
    end.to change(Scheduling::Appointment, :count).by(1)

    expect(response).to have_http_status(:created)
    expect(response_body.dig('payload', 'service_id')).to be_nil
  end

  it 'rejects a Medelement appointment with an unmapped service before persistence' do
    resource.update!(custom_attributes: { 'medelement_specialist_code' => 'specialist-1' })
    params = base_params.merge(
      client_first_name: 'Айжан',
      client_last_name: 'Касымова',
      client_phone: '+77000000001'
    )

    expect do
      post path, params: params, headers: headers, as: :json
    end.not_to change(Scheduling::Appointment, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body['code']).to eq('MEDELEMENT_SERVICE_UNMAPPED')
  end

  it 'creates a Medelement appointment with a mapped service' do
    stub_medelement_availability
    resource.update!(
      custom_attributes: {
        'medelement_specialist_code' => 'specialist-1',
        'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
      }
    )
    service.update!(custom_attributes: { 'medelement_nomenclature_code' => 'service-1' })
    create(:scheduling_service_price, account: account, resource: resource, service: service)
    params = base_params.merge(
      client_first_name: 'Айжан',
      client_last_name: 'Касымова',
      client_phone: '+77000000001',
      custom_attributes: { medelement_cabinet_code: 'cabinet-1' }
    )

    expect do
      post path, params: params, headers: headers, as: :json
    end.to change(Scheduling::Appointment, :count).by(1)

    expect(response).to have_http_status(:created)
    expect(response_body.dig('payload', 'service_id')).to eq(service.id)
    expect(response_body.dig('payload', 'custom_attributes')).to include(
      'medelement_service_binding' => 'local_only',
      'medelement_local_nomenclature_codes' => ['service-1'],
      'medelement_provider_nomenclature_codes' => [],
      'service_ids' => [service.id]
    )
  end

  it 'resolves a linked conversation by display id when creating from a dialog panel' do
    conversation = create(:conversation, account: account, contact: contact)

    post path,
         params: base_params.merge(conversation_display_id: conversation.display_id),
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response_body.dig('payload', 'conversation_id')).to eq(conversation.id)
    expect(response_body.dig('payload', 'conversation_display_id')).to eq(
      conversation.display_id
    )
    expect(
      Scheduling::Appointment.find(response_body.dig('payload', 'id')).conversation_id
    ).to eq(conversation.id)
  end

  it 'falls back to conversation display id for legacy dialog payloads' do
    conversation = create(
      :conversation,
      account: account,
      contact: contact,
      display_id: 659_001
    )

    post path,
         params: base_params.merge(conversation_id: conversation.display_id),
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response_body.dig('payload', 'conversation_id')).to eq(conversation.id)
    expect(response_body.dig('payload', 'conversation_display_id')).to eq(
      conversation.display_id
    )
  end

  it 'resolves a linked conversation by display id when updating from a dialog panel' do
    conversation = create(:conversation, account: account, contact: contact)
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

    put "#{path}/#{appointment.id}",
        params: { conversation_display_id: conversation.display_id },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body.dig('payload', 'conversation_id')).to eq(conversation.id)
    expect(response_body.dig('payload', 'conversation_display_id')).to eq(
      conversation.display_id
    )
    expect(appointment.reload.conversation_id).to eq(conversation.id)
  end

  it 'does not confuse a created conversation display id with another internal id' do
    colliding_id = Conversation.maximum(:id).to_i + 10_000
    other_conversation = create(
      :conversation,
      id: colliding_id,
      account: account,
      contact: contact
    )
    conversation = create(
      :conversation,
      account: account,
      contact: contact,
      display_id: other_conversation.id
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

    put "#{path}/#{appointment.id}",
        params: { conversation_display_id: conversation.display_id },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(appointment.reload.conversation_id).to eq(conversation.id)
    expect(appointment.conversation_id).not_to eq(other_conversation.id)
  end

  # rubocop:disable RSpec/MultipleExpectations
  it 'atomically creates and links a conversation to an appointment' do
    inbox = create(:inbox, account: account, channel: create(:channel_api, account: account))
    create(:inbox_member, user: agent, inbox: inbox)
    contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox)
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

    expect do
      post "#{path}/#{appointment.id}/conversation",
           params: {
             contact_id: contact.id,
             contact_inbox_id: contact_inbox.id,
             inbox_id: inbox.id
           },
           headers: headers,
           as: :json
    end.to change(Conversation, :count).by(1)

    expect(response).to have_http_status(:ok)
    conversation = appointment.reload.conversation
    expect(conversation).to have_attributes(
      account_id: account.id,
      assignee_id: agent.id,
      contact_id: contact.id,
      inbox_id: inbox.id
    )
    expect(response_body.dig('payload', 'conversation_id')).to eq(conversation.id)
    expect(response_body.dig('payload', 'conversation_display_id')).to eq(conversation.display_id)

    expect do
      post "#{path}/#{appointment.id}/conversation",
           params: {
             contact_id: contact.id,
             contact_inbox_id: contact_inbox.id,
             inbox_id: inbox.id
           },
           headers: headers,
           as: :json
    end.not_to change(Conversation, :count)

    expect(response).to have_http_status(:ok)
    expect(appointment.reload.conversation_id).to eq(conversation.id)
    expect(response_body.dig('payload', 'conversation_id')).to eq(conversation.id)
  end
  # rubocop:enable RSpec/MultipleExpectations

  it 'creates and links a conversation without making an imported Medelement appointment editable' do
    inbox = create(:inbox, account: account, channel: create(:channel_api, account: account))
    create(:inbox_member, user: agent, inbox: inbox)
    contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox)
    appointment = create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      contact: contact,
      service: service,
      source: 'medelement',
      external_ref: 'medelement:reception:conversation-test',
      starts_at: booking_day,
      ends_at: booking_day + 30.minutes
    )
    original_attributes = appointment.attributes.except('conversation_id', 'owner_id', 'updated_at')

    expect do
      post "#{path}/#{appointment.id}/conversation",
           params: {
             contact_id: contact.id,
             contact_inbox_id: contact_inbox.id,
             inbox_id: inbox.id
           },
           headers: headers,
           as: :json
    end.to change(Conversation, :count).by(1)

    expect(response).to have_http_status(:ok)
    expect(appointment.reload).to have_attributes(
      conversation_id: be_present,
      owner_id: agent.id,
      source: 'medelement',
      external_ref: 'medelement:reception:conversation-test'
    )
    expect(appointment.attributes.except('conversation_id', 'owner_id', 'updated_at')).to eq(original_attributes)
    expect(response_body.dig('payload', 'external_conversation_creation_supported')).to be(true)
  end

  it 'rejects a contact inbox outside the selected contact and inbox scope' do
    inbox = create(:inbox, account: account, channel: create(:channel_api, account: account))
    create(:inbox_member, user: agent, inbox: inbox)
    another_contact = create(:contact, account: account)
    another_contact_inbox = create(:contact_inbox, contact: another_contact, inbox: inbox)
    appointment = create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      contact: contact,
      service: service,
      starts_at: booking_day,
      ends_at: booking_day + 30.minutes
    )

    expect do
      post "#{path}/#{appointment.id}/conversation",
           params: {
             contact_id: contact.id,
             contact_inbox_id: another_contact_inbox.id,
             inbox_id: inbox.id
           },
           headers: headers,
           as: :json
    end.not_to change(Conversation, :count)

    expect(response).to have_http_status(:not_found)
    expect(appointment.reload.conversation_id).to be_nil
  end

  it 'rejects a conversation that belongs to another contact' do
    another_contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: another_contact)
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

    put "#{path}/#{appointment.id}",
        params: { conversation_display_id: conversation.display_id },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(appointment.reload.conversation_id).to be_nil
  end

  it 'clears the linked conversation when conversation_id is explicitly blank' do
    conversation = create(:conversation, account: account, contact: contact)
    appointment = create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      contact: contact,
      conversation: conversation,
      service: service,
      service_amount: 20_000,
      starts_at: booking_day,
      ends_at: booking_day + 30.minutes
    )

    put "#{path}/#{appointment.id}",
        params: { conversation_id: nil },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body.dig('payload', 'conversation_id')).to be_nil
    expect(appointment.reload.conversation_id).to be_nil
  end

  it 'separates an explicit appointment target from legacy inferred contact history' do
    conversation = create(:conversation, account: account, contact: contact)
    communication_thread = create(:communication_thread, account: account, contact: contact)
    create(
      :communication_thread_conversation,
      account: account,
      communication_thread: communication_thread,
      conversation: conversation,
      primary: true
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

    get "#{path}/#{appointment.id}", headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body.fetch('payload')).to include(
      'conversation_id' => nil,
      'conversation_display_id' => nil,
      'appointment_conversation_id' => nil,
      'appointment_conversation_display_id' => nil,
      'appointment_communication_thread_id' => nil,
      'appointment_communication_thread_display_id' => nil,
      'conversation_creation_supported' => true,
      'communication_thread_id' => communication_thread.id,
      'communication_thread_display_id' => communication_thread.display_id,
      'chat_conversation_id' => conversation.id,
      'chat_conversation_display_id' => conversation.display_id
    )
  end

  it 'ignores an unavailable contact conversation when building the appointment drawer chat target' do
    unavailable_inbox = create(:inbox, account: account)
    unavailable_conversation = create(
      :conversation,
      account: account,
      contact: contact,
      inbox: unavailable_inbox
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
    unavailable_inbox.delete

    get "#{path}/#{appointment.id}", headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body.fetch('payload')).to include(
      'conversation_id' => nil,
      'conversation_display_id' => nil,
      'appointment_conversation_id' => nil,
      'appointment_conversation_display_id' => nil,
      'conversation_creation_supported' => true,
      'communication_thread_id' => nil,
      'communication_thread_display_id' => nil,
      'chat_conversation_id' => unavailable_conversation.id,
      'chat_conversation_display_id' => unavailable_conversation.display_id
    )
    expect(unavailable_conversation.reload.inbox).to be_nil
  end

  it 'ignores an explicitly linked conversation when its inbox is unavailable' do
    unavailable_inbox = create(:inbox, account: account)
    unavailable_conversation = create(
      :conversation,
      account: account,
      contact: contact,
      inbox: unavailable_inbox
    )
    appointment = create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      contact: contact,
      conversation: unavailable_conversation,
      service: service,
      service_amount: 20_000,
      starts_at: booking_day,
      ends_at: booking_day + 30.minutes
    )
    unavailable_inbox.delete

    get "#{path}/#{appointment.id}", headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body.fetch('payload')).to include(
      'conversation_id' => nil,
      'conversation_display_id' => nil,
      'appointment_conversation_id' => nil,
      'appointment_conversation_display_id' => nil,
      'conversation_creation_supported' => true,
      'communication_thread_id' => nil,
      'communication_thread_display_id' => nil,
      'chat_conversation_id' => unavailable_conversation.id,
      'chat_conversation_display_id' => unavailable_conversation.display_id
    )
    expect(appointment.reload.conversation_id).to eq(unavailable_conversation.id)
  end

  # rubocop:disable RSpec/MultipleExpectations
  it 'keeps an explicit appointment conversation ahead of a separate contact thread target' do
    explicit_conversation = create(:conversation, account: account, contact: contact)
    thread_conversation = create(:conversation, account: account, contact: contact)
    communication_thread = create(:communication_thread, account: account, contact: contact)
    create(
      :communication_thread_conversation,
      account: account,
      communication_thread: communication_thread,
      conversation: thread_conversation,
      primary: true
    )
    appointment = create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      contact: contact,
      conversation: explicit_conversation,
      service: service,
      service_amount: 20_000,
      starts_at: booking_day,
      ends_at: booking_day + 30.minutes
    )

    get "#{path}/#{appointment.id}", headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body.dig('payload', 'conversation_id')).to eq(explicit_conversation.id)
    expect(response_body.dig('payload', 'conversation_display_id')).to eq(explicit_conversation.display_id)
    expect(response_body.dig('payload', 'appointment_conversation_id')).to eq(explicit_conversation.id)
    expect(response_body.dig('payload', 'appointment_conversation_display_id')).to eq(explicit_conversation.display_id)
    expect(response_body.dig('payload', 'conversation_creation_supported')).to be(true)
    expect(response_body.dig('payload', 'communication_thread_id')).to be_nil
    expect(response_body.dig('payload', 'communication_thread_display_id')).to be_nil
    expect(response_body.dig('payload', 'chat_conversation_id')).to eq(explicit_conversation.id)
    expect(response_body.dig('payload', 'chat_conversation_display_id')).to eq(explicit_conversation.display_id)
  end
  # rubocop:enable RSpec/MultipleExpectations

  it 'creates a no-service appointment with a manual service name snapshot' do
    post path,
         params: base_params.except(:service_id).merge(
           service_name_snapshot: 'Осмотр',
           service_amount: 12_000
         ),
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response_body.dig('payload', 'service_id')).to be_nil
    expect(response_body.dig('payload', 'service_name_snapshot')).to eq('Осмотр')
    expect(response_body.dig('payload', 'service_amount')).to eq(12_000)
    expect(
      Scheduling::Appointment.find(response_body.dig('payload', 'id')).service_name_snapshot
    ).to eq('Осмотр')
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

  it 'accepts the Medelement cabinet intake field when managed definitions exist' do
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'appointment',
      key: 'visit_reason',
      label: 'Visit reason',
      field_type: 'text'
    )

    post path,
         params: base_params.merge(
           custom_attributes: {
             visit_reason: 'Initial visit',
             medelement_cabinet_code: 'cabinet-501'
           }
         ),
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response_body.dig('payload', 'custom_attributes')).to include(
      'visit_reason' => 'Initial visit',
      'medelement_cabinet_code' => 'cabinet-501'
    )
  end

  it 'accepts the Medelement cabinet intake field without managed definitions' do
    post path,
         params: base_params.merge(custom_attributes: { medelement_cabinet_code: 'cabinet-501' }),
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response_body.dig('payload', 'custom_attributes', 'medelement_cabinet_code')).to eq('cabinet-501')
  end

  it 'does not allow arbitrary Medelement system fields through appointment intake' do
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'appointment',
      key: 'visit_reason',
      label: 'Visit reason',
      field_type: 'text'
    )

    post path,
         params: base_params.merge(custom_attributes: { medelement_provider_sync_status: 'succeeded' }),
         headers: headers,
         as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body.dig('details', 'custom_attributes.medelement_provider_sync_status'))
      .to include('is managed by the system')
  end

  it 'does not allow arbitrary Medelement system fields without managed definitions' do
    post path,
         params: base_params.merge(custom_attributes: { medelement_provider_sync_status: 'succeeded' }),
         headers: headers,
         as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body.dig('details', 'custom_attributes.medelement_provider_sync_status'))
      .to include('is managed by the system')
  end

  it 'rebuilds derived service metadata instead of accepting custom attribute values' do
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
        'service_ids' => [service.id],
        'services' => [{ 'id' => service.id, 'name' => service.name }]
      }
    )

    put "#{path}/#{appointment.id}",
        params: {
          service_ids: [service.id],
          custom_attributes: {
            visit_reason: 'Follow up',
            service_ids: [999_999],
            services: [{ id: 999_999, name: 'Spoofed' }]
          }
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body.dig('payload', 'custom_attributes')).to include('visit_reason' => 'Follow up')
    expect(response_body.dig('payload', 'custom_attributes', 'service_ids')).to eq([service.id])
    expect(response_body.dig('payload', 'custom_attributes', 'services').pluck('id')).to eq([service.id])
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
          custom_attributes: {
            medelement_reception_code: '42',
            visit_reason: 'follow up'
          }
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

    lookup = instance_double(Integrations::Medelement::AppointmentProviderCommandReceiptLookupService, perform: nil)
    expect(Integrations::Medelement::AppointmentProviderCommandReceiptLookupService).to receive(:new).with(
      account: account,
      appointment: have_attributes(id: created_id),
      operation: 'create_reception'
    ).and_return(lookup)

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

  it 'ignores client-supplied appointment source while preserving generic external references' do
    post path,
         params: base_params.merge(source: 'medelement', external_ref: 'external-booking-1'),
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response_body.dig('payload', 'source')).to eq('manual')
    expect(response_body.dig('payload', 'external_ref')).to eq('external-booking-1')
  end

  it 'rejects client-supplied external references from the Medelement namespace' do
    post path,
         params: base_params.merge(external_ref: ' medelement:reception:spoofed'),
         headers: headers,
         as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body['code']).to eq('APPOINTMENT_EXTERNAL_REF_RESERVED')
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

  it 'clears an existing service when updating with an explicit empty service list' do
    appointment = create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      contact: contact,
      service: service,
      service_amount: 20_000,
      custom_attributes: {
        'service_ids' => [service.id],
        'services' => [
          {
            'id' => service.id,
            'name' => service.name,
            'duration_min' => service.duration_min
          }
        ]
      },
      starts_at: booking_day,
      ends_at: booking_day + 30.minutes
    )

    put "#{path}/#{appointment.id}",
        params: {
          service_amount: 22_000,
          service_ids: [],
          service_name_snapshot: 'Ручная услуга'
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body.dig('payload', 'service_id')).to be_nil
    expect(response_body.dig('payload', 'service_ids')).to eq([])
    expect(response_body.dig('payload', 'service_name_snapshot')).to eq('Ручная услуга')
    expect(response_body.dig('payload', 'service_amount')).to eq(22_000)

    appointment.reload
    expect(appointment.service_id).to be_nil
    expect(appointment.custom_attributes).not_to include('service_ids', 'services')
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
      prepaid_payment_method: 'bank_transfer',
      payment_status: 'prepaid',
      starts_at: booking_day,
      ends_at: booking_day + 30.minutes
    )
    create(
      :scheduling_payment,
      appointment: appointment,
      account: account,
      amount: 5_000,
      payment_method: 'bank_transfer',
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

  it 'routes an imported appointment cancellation update through the provider-safe cancel service' do
    appointment = create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      contact: contact,
      service: service,
      source: 'medelement',
      external_ref: 'medelement:reception:1'
    )
    cancel_service = instance_double(Scheduling::Appointments::CancelService, perform: appointment)
    expect(Scheduling::Appointments::CancelService).to receive(:new).with(
      appointment: appointment,
      actor: agent
    ).and_return(cancel_service)

    put "#{path}/#{appointment.id}",
        params: { status: 'cancelled', client_name: 'Ignored edit' },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body.dig('payload', 'source')).to eq('medelement')
    expect(appointment.reload.client_name).not_to eq('Ignored edit')
  end

  it 'returns a stable calendar payload shape' do
    conversation = create(:conversation, account: account, contact: contact)
    appointment = create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      contact: contact,
      conversation: conversation,
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
    expect(response_body.dig('payload', 'appointments', 0, 'conversation_display_id')).to eq(conversation.display_id)
  end

  it 'accepts resource_ids as an array and filters the calendar payload' do
    other_resource = create(:scheduling_resource, account: account, timezone: 'Asia/Almaty')

    get "/api/v1/accounts/#{account.id}/scheduling/calendar",
        params: {
          view: 'week',
          from: booking_day.beginning_of_day.iso8601,
          to: (booking_day + 7.days).end_of_day.iso8601,
          resource_ids: [resource.id]
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body.dig('payload', 'resources').pluck('id')).to eq([resource.id])
    expect(response_body.dig('payload', 'resources').pluck('id')).not_to include(other_resource.id)
  end

  it 'normalizes CSV and array resource_ids to the same resources and slots' do
    other_resource = create(:scheduling_resource, account: account, timezone: 'Asia/Almaty')
    resource_ids = [resource.id, other_resource.id]
    request_params = {
      view: 'week',
      from: booking_day.beginning_of_day.iso8601,
      to: (booking_day + 7.days).end_of_day.iso8601,
      include_slots: true
    }

    get "/api/v1/accounts/#{account.id}/scheduling/calendar",
        params: request_params.merge(resource_ids: resource_ids.join(',')), headers: headers, as: :json
    string_result = response_body.fetch('payload')
    get "/api/v1/accounts/#{account.id}/scheduling/calendar",
        params: request_params.merge(resource_ids: resource_ids), headers: headers, as: :json
    array_result = response_body.fetch('payload')

    expect(array_result.fetch('resources').pluck('id')).to eq(string_result.fetch('resources').pluck('id'))
    expect(array_result.fetch('slots').size).to eq(string_result.fetch('slots').size)
  end

  it 'rejects malformed calendar resource_ids instead of returning empty availability' do
    get "/api/v1/accounts/#{account.id}/scheduling/calendar",
        params: {
          view: 'week',
          from: booking_day.beginning_of_day.iso8601,
          to: (booking_day + 7.days).end_of_day.iso8601,
          resource_ids: ['invalid']
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body).to include(
      'code' => 'VALIDATION_ERROR',
      'error' => 'resource_ids must contain positive integer IDs'
    )
  end

  [{ unexpected: 42 }, [[42]], [true]].each do |malformed_resource_ids|
    it "rejects malformed resource_ids #{malformed_resource_ids.inspect}" do
      get "/api/v1/accounts/#{account.id}/scheduling/calendar",
          params: {
            view: 'week',
            from: booking_day.beginning_of_day.iso8601,
            to: (booking_day + 7.days).end_of_day.iso8601,
            resource_ids: malformed_resource_ids
          },
          headers: headers,
          as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response_body['code']).to eq('VALIDATION_ERROR')
    end
  end

  it 'returns not found for an unknown calendar resource_id' do
    unknown_id = Scheduling::Resource.maximum(:id).to_i + 10_000

    get "/api/v1/accounts/#{account.id}/scheduling/calendar",
        params: {
          view: 'week',
          from: booking_day.beginning_of_day.iso8601,
          to: (booking_day + 7.days).end_of_day.iso8601,
          resource_ids: unknown_id.to_s
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:not_found)
    expect(response_body).to include('error' => 'Resource could not be found')
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

  it 'filters calendar appointments by status and payment status' do
    attributes = { account: account, contact: contact, resource: resource, service: service }
    matching_appointment = create(
      :scheduling_appointment,
      **attributes,
      starts_at: booking_day,
      ends_at: booking_day + 30.minutes,
      status: 'confirmed',
      payment_status: 'paid'
    )
    create(
      :scheduling_appointment,
      **attributes,
      starts_at: booking_day + 1.hour,
      ends_at: booking_day + 90.minutes,
      status: 'scheduled',
      payment_status: 'paid'
    )
    create(
      :scheduling_appointment,
      **attributes,
      starts_at: booking_day + 2.hours,
      ends_at: booking_day + 150.minutes,
      status: 'confirmed',
      payment_status: 'awaiting_payment'
    )

    get "/api/v1/accounts/#{account.id}/scheduling/calendar",
        params: {
          view: 'week',
          from: booking_day.beginning_of_day.iso8601,
          to: (booking_day + 7.days).end_of_day.iso8601,
          status: 'confirmed',
          payment_status: 'paid'
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

  it 'filters appointments index by conversation display id for dialog panels' do
    conversation = create(:conversation, account: account, contact: contact)
    matching_appointment = create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      contact: contact,
      service: service,
      conversation: conversation,
      starts_at: booking_day,
      ends_at: booking_day + 30.minutes
    )
    create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      contact: contact,
      service: service,
      starts_at: booking_day + 1.hour,
      ends_at: booking_day + 90.minutes
    )

    get path,
        params: { conversation_display_ids: conversation.display_id },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body['payload'].pluck('id')).to eq([matching_appointment.id])
    expect(response_body.dig('payload', 0, 'conversation_display_id')).to eq(conversation.display_id)
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
    expect(response_body['payload'].pluck('id')).to eq([matching_appointment.id])
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
