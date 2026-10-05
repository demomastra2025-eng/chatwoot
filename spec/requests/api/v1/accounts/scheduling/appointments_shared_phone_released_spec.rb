require 'rails_helper'

# Owner decision 2026-09-30 (M1/M2, switches off by default): a card's доп. номер never becomes its primary on its own. When
# the holder of the family number gives it up and nobody chats from it on a phone channel, an appointment update, a
# repeated booking of the same card or a sibling's update still keeps the number as the card's доп. номер; only
# Contacts::SharedPhonePromotionService (behind Contacts::SharedPhoneSwitches) may make it a primary.
RSpec.describe 'Scheduling appointments after the family number holder released it', type: :request do
  include ActiveJob::TestHelper

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
  let(:family_phone) { SharedPhoneHelpers::FAMILY_PHONE }
  let(:other_phone) { '+77000000001' }
  let(:shared) { Contacts::SharedPhone }
  let(:booking_day) do
    timezone = ActiveSupport::TimeZone['Asia/Almaty']
    date = timezone.today.next_occurring(:monday)
    timezone.local(date.year, date.month, date.day, 10, 0, 0)
  end
  # The mother shows the family number but writes from a chat that is not a phone identity (widget).
  let(:mother) { create(:contact, account: account, name: 'Mother', phone_number: family_phone) }
  let(:conversation) { create(:conversation, account: account, contact: mother) }

  before do
    stub_request(:any, /evolution\.example\.com/).to_return(status: 200, body: '{}', headers: { 'Content-Type' => 'application/json' })
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

  def book!(first_name, iin:, owner: mother, chat: conversation, offset: 0)
    starts_at = booking_day + offset.minutes
    post path, params: { resource_id: resource.id, contact_id: owner.id, conversation_id: chat.id, service_id: service.id,
                         starts_at: starts_at.iso8601, ends_at: (starts_at + 30.minutes).iso8601, client_first_name: first_name,
                         client_last_name: 'Patient', client_name: "#{first_name} Patient", client_phone: family_phone,
                         client_identifier: iin, service_amount: 20_000, custom_attributes: { medelement_cabinet_code: 'cabinet-1' } },
               headers: headers, as: :json
    expect(response).to have_http_status(:success)
    Scheduling::Appointment.find(response.parsed_body.dig('payload', 'id'))
  end

  def touch!(appointment)
    patch "#{path}/#{appointment.id}", params: { client_comment: 'rescheduled by phone' }, headers: headers, as: :json
    expect(response).to have_http_status(:success)
  end

  def release!(contact)
    perform_enqueued_jobs(only: Contacts::SharedPhoneReleasedJob) { contact.update!(phone_number: other_phone) }
  end

  def expect_family_number_kept(card, owner: mother)
    expect(card.reload.phone_number).to be_nil
    expect(shared.secondary_phones(card)).to include(family_phone)
    expect(shared.share_of(card)).to have_attributes(phone: family_phone, owner_id: owner.id)
  end

  it 'ships with every shared-number switch off' do
    expect(Contacts::SharedPhoneSwitches.states.values).to all(be(false))
  end

  it 'an appointment update keeps the доп. номер and the next WhatsApp chat from the number is not filed under the card',
     :aggregate_failures do
    appointment = book!('Son', iin: '940720300129')
    card = appointment.patient_contact
    expect_family_number_kept(card)

    release!(mother)
    touch!(appointment)

    expect_family_number_kept(card)
    expect(account.contacts.where(phone_number: family_phone)).to be_empty
    contact_inbox = ContactInboxWithContactBuilder.new(inbox: shared_phone_cloud_inbox(account), source_id: family_phone.delete('+'),
                                                       contact_attributes: { name: 'Mother', phone_number: family_phone }).perform
    expect(contact_inbox.contact_id).not_to eq(card.id)
    expect(shared.card?(contact_inbox.contact)).to be(false)
  end

  it 'booking the same card again keeps the доп. номер', :aggregate_failures do
    card = book!('Son', iin: '940720300129').patient_contact
    release!(mother)

    second = book!('Son', iin: '940720300129', offset: 60)

    expect(second.patient_contact_id).to eq(card.id)
    expect_family_number_kept(card)
  end

  it 'a hidden-number share keeps the доп. номер after staff give the LID-only mother another number of her own',
     :aggregate_failures do
    inbox = create(:channel_whatsapp_web, account: account).inbox
    lid_mother = create(:contact, account: account, name: 'Mother', phone_number: nil, identifier: 'whatsapp_web:55555@lid')
    lid_inbox = create(:contact_inbox, contact: lid_mother, inbox: inbox, source_id: '55555@lid')
    lid_chat = create(:conversation, account: account, inbox: inbox, contact: lid_mother, contact_inbox: lid_inbox)
    appointment = book!('Son', iin: '940720300129', owner: lid_mother, chat: lid_chat)
    card = appointment.patient_contact
    expect(shared.share_of(card)).to have_attributes(via: shared::VIA_BOOKING_CHAT, owner_id: lid_mother.id)

    release!(lid_mother)
    touch!(appointment)

    expect_family_number_kept(card, owner: lid_mother)
  end

  it 'touching one sibling appointment picks neither sibling', :aggregate_failures do
    son = book!('Son', iin: '940720300129').patient_contact
    daughter_appointment = book!('Daughter', iin: '050101500010', offset: 60)
    daughter = daughter_appointment.patient_contact
    expect(daughter.id).not_to eq(son.id)

    release!(mother)
    touch!(daughter_appointment)

    expect_family_number_kept(daughter)
    expect_family_number_kept(son)
    # Even once MedElement confirms the number as the daughter's own, the sibling keeps it from being promoted (M5b).
    daughter.update!(custom_attributes: daughter.custom_attributes.merge(shared::MEDELEMENT_PHONE_KEY => family_phone))
    expect(Contacts::SharedPhonePromotionPolicy.auto_decision(daughter, check_switches: false).reason).to eq(:siblings)
  end
end
