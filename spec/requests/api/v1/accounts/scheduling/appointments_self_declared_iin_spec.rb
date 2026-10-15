require 'rails_helper'

# M8 (reviewer W1a/W1b): a widget visitor can set its own identifier or custom 'iin' without HMAC. Such a self-declared
# IIN never decides which card a booking binds to and never blocks the patient's bookings with an identity conflict.
RSpec.describe 'Scheduling appointments and self-declared patient IINs', type: :request do
  around do |example|
    with_modified_env('EVOLUTION_API_URL' => 'https://evolution.example.com', 'EVOLUTION_API_KEY' => 'test-api-key',
                      'FRONTEND_URL' => 'https://app.example.com') { example.run }
  end

  let(:account) { create(:account, limits: { non_web_inboxes: ChatwootApp.max_limit }) }
  let(:resource) { create(:scheduling_resource, account: account, timezone: 'Asia/Almaty') }
  let(:service) { create(:scheduling_service, account: account, base_price: 20_000) }
  let(:headers) { create(:user, account: account, role: :agent).create_new_auth_token }
  let(:widget) { create(:channel_widget, account: account) }
  let(:booking_chat) do
    inbox = create(:channel_whatsapp_web, account: account).inbox
    owner = create(:contact, account: account, name: 'Mother', phone_number: nil, identifier: 'whatsapp_web:55555@lid')
    create(:conversation, account: account, inbox: inbox, contact: owner,
                          contact_inbox: create(:contact_inbox, contact: owner, inbox: inbox, source_id: '55555@lid'))
  end

  before do
    create(:scheduling_work_rule, resource: resource, account: account, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)
    account.enable_features!('scheduling')
    result = Integrations::Medelement::ResourceAvailabilityService::Result.new(status: 'fresh', checked_at: Time.current, slots: [{}], reason: nil)
    allow(Integrations::Medelement::ResourceAvailabilityService).to receive(:new)
      .and_return(instance_double(Integrations::Medelement::ResourceAvailabilityService, perform: result))
    resource.update!(custom_attributes: { 'medelement_specialist_code' => 'specialist-1',
                                          'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }] })
    service.update!(custom_attributes: { 'medelement_nomenclature_code' => 'service-1' })
    create(:scheduling_service_price, account: account, resource: resource, service: service)
  end

  def iin = '940720300129'
  def path = "/api/v1/accounts/#{account.id}/scheduling/appointments"

  def booking_params(starts)
    { resource_id: resource.id, contact_id: booking_chat.contact_id, conversation_id: booking_chat.id, service_id: service.id,
      starts_at: starts.iso8601, ends_at: (starts + 30.minutes).iso8601, client_first_name: 'Child', client_last_name: 'Patient',
      client_name: 'Child Patient', client_phone: '+77000000009', client_identifier: iin, service_amount: 20_000,
      custom_attributes: { medelement_cabinet_code: 'cabinet-1' } }
  end

  def book!(day_offset: 0)
    timezone = ActiveSupport::TimeZone['Asia/Almaty']
    date = timezone.today.next_occurring(:monday) + day_offset.days
    post path, params: booking_params(timezone.local(date.year, date.month, date.day, 10, 0, 0)), headers: headers, as: :json
    appointment_id = response.parsed_body.dig('payload', 'id')
    appointment_id && Scheduling::Appointment.find(appointment_id)
  end

  def claim_as_visitor!(visitor, params)
    visitor_inbox = create(:contact_inbox, contact: visitor, inbox: widget.inbox)
    token = Widget::TokenService.new(payload: { source_id: visitor_inbox.source_id, inbox_id: widget.inbox.id }).generate_token
    patch '/api/v1/widget/contact', params: params.merge(website_token: widget.website_token), headers: { 'X-Auth-Token' => token }, as: :json
  end

  it 'W1a a visitor that claimed the IIN as its identifier first neither decides nor blocks the booking', :aggregate_failures do
    visitor = create(:contact, account: account, name: 'Visitor')
    claim_as_visitor!(visitor, { identifier: iin })
    expect(visitor.reload.identifier).to eq(iin)

    appointment = book!

    expect(response).to have_http_status(:success)
    card = appointment.patient_contact
    expect(card.id).not_to eq(visitor.id)
    expect(card.custom_attributes).to include('iin' => iin, Contacts::SharedPhone::CARD_KEY => true)
    expect(visitor.reload.identifier).to eq(iin)
  end

  it 'W1b a visitor that claims the IIN after the card exists blocks neither edits nor new bookings', :aggregate_failures do
    appointment = book!
    visitor = create(:contact, account: account, name: 'Visitor')
    claim_as_visitor!(visitor, { custom_attributes: { iin: iin } })
    expect(visitor.reload.custom_attributes['iin']).to eq(iin)

    patch "#{path}/#{appointment.id}", params: { client_first_name: 'Child', client_identifier: iin, notes: 'edit' }, headers: headers, as: :json
    expect(response).to have_http_status(:success)

    second = book!(day_offset: 7)
    expect(response).to have_http_status(:success)
    expect(second.patient_contact_id).to eq(appointment.patient_contact_id)
  end
end
