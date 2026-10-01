require 'rails_helper'

# Round-8 A1 end to end through the appointments API: book a child from a LID-only WhatsApp Web chat without an IIN,
# add the IIN later, then the chat reveals the family number. Owner model 2026-09-29: the chat contact is kept with its
# conversation and messages; the card has the number only as доп. номер; the replaced draft holds nothing.
RSpec.describe 'Scheduling appointments with a hidden family number', type: :request do
  around do |example|
    with_modified_env('EVOLUTION_API_URL' => 'https://evolution.example.com', 'EVOLUTION_API_KEY' => 'test-api-key',
                      'FRONTEND_URL' => 'https://app.example.com') { example.run }
  end

  let(:account) { create(:account, limits: { non_web_inboxes: ChatwootApp.max_limit }) }
  let(:resource) { create(:scheduling_resource, account: account, timezone: 'Asia/Almaty') }
  let(:service) { create(:scheduling_service, account: account, base_price: 20_000) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:headers) { agent.create_new_auth_token }
  let(:path) { "/api/v1/accounts/#{account.id}/scheduling/appointments" }
  let(:booking_day) do
    timezone = ActiveSupport::TimeZone['Asia/Almaty']
    date = timezone.today.next_occurring(:monday)
    timezone.local(date.year, date.month, date.day, 10, 0, 0)
  end
  let(:inbox) { create(:channel_whatsapp_web, account: account).inbox }
  let(:owner) { create(:contact, account: account, name: 'Mother', phone_number: nil, identifier: 'whatsapp_web:55555@lid') }
  let(:owner_contact_inbox) { create(:contact_inbox, contact: owner, inbox: inbox, source_id: '55555@lid') }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: owner, contact_inbox: owner_contact_inbox) }
  let(:shared) { Contacts::SharedPhone }
  let(:booking_params) do
    {
      resource_id: resource.id,
      contact_id: owner.id,
      conversation_id: conversation.id,
      service_id: service.id,
      starts_at: booking_day.iso8601,
      ends_at: (booking_day + 30.minutes).iso8601,
      client_first_name: 'Child',
      client_last_name: 'Patient',
      client_name: 'Child Patient',
      client_phone: '+77000000009',
      service_amount: 20_000,
      custom_attributes: { medelement_cabinet_code: 'cabinet-1' }
    }
  end

  before do
    create(:scheduling_work_rule, resource: resource, account: account, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)
    account.enable_features!('scheduling', 'scheduling_finance')
    create(:message, account: account, inbox: inbox, conversation: conversation, sender: owner, message_type: :incoming)
    result = Integrations::Medelement::ResourceAvailabilityService::Result.new(status: 'fresh', checked_at: Time.current, slots: [{}], reason: nil)
    allow(Integrations::Medelement::ResourceAvailabilityService).to receive(:new)
      .and_return(instance_double(Integrations::Medelement::ResourceAvailabilityService, perform: result))
    resource.update!(custom_attributes: { 'medelement_specialist_code' => 'specialist-1',
                                          'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }] })
    service.update!(custom_attributes: { 'medelement_nomenclature_code' => 'service-1' })
    create(:scheduling_service_price, account: account, resource: resource, service: service)
  end

  it 'A1 POST without IIN, PATCH with IIN, then the LID resolves to the booking number', :aggregate_failures do
    post path, params: booking_params, headers: headers, as: :json
    expect(response).to have_http_status(:success)
    appointment = Scheduling::Appointment.find(response.parsed_body.dig('payload', 'id'))
    first = appointment.patient_contact
    expect(first.phone_number).to be_nil

    patch "#{path}/#{appointment.id}", params: { client_identifier: '940720300129' }, headers: headers, as: :json
    expect(response).to have_http_status(:success)
    second = appointment.reload.patient_contact

    payload = { remoteJid: '77000000009@s.whatsapp.net', remoteLid: '55555@lid', pushName: 'Mother' }
    WhatsappWeb::ContactSyncService.new(channel: inbox.channel, contact_payload: payload).perform

    expect(owner.reload.phone_number).to eq('+77000000009')
    expect(conversation.reload.contact_id).to eq(owner.id)
    expect(Message.where(conversation_id: conversation.id, message_type: :incoming).pluck(:sender_id).uniq).to eq([owner.id])
    expect(appointment.reload).to have_attributes(contact_id: owner.id, patient_contact_id: second.id)
    expect(second.reload.phone_number).to be_nil
    expect(second.custom_attributes).to include('secondary_phones' => ['+77000000009'], shared::SHARED_OWNER_KEY => owner.id)
    expect(first.id == second.id || first.reload.phone_number.nil?).to be(true)
  end
end
