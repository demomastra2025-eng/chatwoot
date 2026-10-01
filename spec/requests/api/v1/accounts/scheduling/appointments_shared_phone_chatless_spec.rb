require 'rails_helper'

# sc8rv1 round 3 H2c (regression ports of the reviewer probes): a family member's reminder for an appointment without a
# booking chat (booked from a contact page, MedElement import) must never reach a stranger that attached itself to the
# share owner or holder through an unverified channel (widget identify by email, public API contact create). It goes
# only through the holder's own phone chat on the number, or nowhere (fail closed, visible to staff).
RSpec.describe 'Chatless appointments of a family number', type: :request do
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  around do |example|
    with_modified_env('EVOLUTION_API_URL' => 'https://evolution.example.com', 'EVOLUTION_API_KEY' => 'test-api-key',
                      'FRONTEND_URL' => 'https://app.example.com') { example.run }
  end

  let(:family) { '+77000000009' }
  let(:family_digits) { '77000000009' }
  let(:child_iin) { '940720300129' }
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
  let(:web_inbox) { create(:channel_whatsapp_web, account: account).inbox }
  let(:widget) { create(:channel_widget, account: account) }
  let(:api_channel) { create(:channel_api, account: account, webhook_url: nil) }

  before do
    stub_request(:any, /evolution\.example\.com/).to_return(status: 200, body: '{}', headers: { 'Content-Type' => 'application/json' })
    create(:scheduling_work_rule, resource: resource, account: account, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)
    account.enable_features!('scheduling', 'scheduling_finance')
    result = Integrations::Medelement::ResourceAvailabilityService::Result.new(status: 'fresh', checked_at: Time.current, slots: [{}], reason: nil)
    allow(Integrations::Medelement::ResourceAvailabilityService).to receive(:new)
      .and_return(instance_double(Integrations::Medelement::ResourceAvailabilityService, perform: result))
    resource.update!(custom_attributes: { 'medelement_specialist_code' => 'specialist-1',
                                          'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }] })
    service.update!(custom_attributes: { 'medelement_nomenclature_code' => 'service-1' })
    create(:scheduling_service_price, account: account, resource: resource, service: service)
    fresh = Integrations::Medelement::AppointmentFreshnessVerifier::Result.new(status: 'fresh', reason: nil, checked_at: Time.current,
                                                                               command_id: nil, command_status: nil)
    allow_any_instance_of(Integrations::Medelement::AppointmentFreshnessVerifier).to receive(:perform).and_return(fresh) # rubocop:disable RSpec/AnyInstance
  end

  def chat(contact, inbox, source_id = nil, at: nil)
    contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox, **{ source_id: source_id }.compact)
    conversation = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
    conversation.update_columns(last_activity_at: at) if at # rubocop:disable Rails/SkipsModelValidations
    create(:message, account: account, inbox: inbox, conversation: conversation, sender: contact, message_type: :incoming)
    [contact_inbox, conversation]
  end

  def book!(owner, phone: family)
    post path, params: { resource_id: resource.id, contact_id: owner.id, service_id: service.id, starts_at: booking_day.iso8601,
                         ends_at: (booking_day + 30.minutes).iso8601, client_first_name: 'Child', client_last_name: 'Patient',
                         client_name: 'Child Patient', client_phone: phone, service_amount: 20_000, client_identifier: child_iin,
                         custom_attributes: { medelement_cabinet_code: 'cabinet-1' } }, headers: headers, as: :json
    expect(response).to have_http_status(:created)
    Scheduling::Appointment.find(response.parsed_body.dig('payload', 'id'))
  end

  def default_plan!(body)
    group = create(:reminder_group, account: account, touches: [{
                     action_type: 'send_message', content_kind: 'free_text', text_mode: 'static', timing_mode: 'relative',
                     relative_anchor: 'appointment.starts_at', relative_offset_seconds: -86_400, timezone: 'UTC', body: body,
                     attachments: [], template_params: {}, metadata: {}
                   }])
    account.update!(default_appointment_touch_plan_id: group.id)
  end

  # Runs the due touch like the scheduler does; an undeliverable touch fails visibly (the job discards the error).
  def force_run!(touch)
    travel_to(touch.scheduled_at + 1.minute) do
      touch.update_columns(status: Reminder.statuses[:processing], processing_started_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
      begin
        Reminders::ExecuteService.new(reminder: touch.reload).perform
      rescue Reminders::UndeliverableTargetError
        nil
      end
    end
    touch.reload
  end

  def touch_messages(touch)
    Message.outgoing.where(account_id: account.id).where("additional_attributes ->> 'touch_id' = ?", touch.id.to_s)
  end

  def stranger_widget_session!(email)
    visitor = create(:contact, account: account, name: 'Stranger')
    visitor_ci = create(:contact_inbox, contact: visitor, inbox: widget.inbox)
    token = Widget::TokenService.new(payload: { source_id: visitor_ci.source_id, inbox_id: widget.inbox.id }).generate_token
    widget_headers = { 'X-Auth-Token' => token }
    patch '/api/v1/widget/contact', params: { website_token: widget.website_token, email: email }, headers: widget_headers, as: :json
    post '/api/v1/widget/conversations', params: { website_token: widget.website_token, message: { content: 'hello' } },
                                         headers: widget_headers, as: :json
    widget_headers
  end

  def visible_in_widget?(widget_headers, body)
    get '/api/v1/widget/messages', params: { website_token: widget.website_token }, headers: widget_headers, as: :json
    response.body.include?(body)
  end

  def expect_fail_closed(touch)
    expect(touch).to have_attributes(target_contact_id: nil, target_contact_inbox_id: nil, target_conversation_id: nil)
    expect(touch).to be_route_reassignment_required
    ran = force_run!(touch)
    expect(ran).not_to be_completed
    expect(touch_messages(ran)).to be_empty
  end

  def lid_mother(email)
    mother = create(:contact, account: account, name: 'Mother', phone_number: nil, identifier: 'whatsapp_web:55555@lid', email: email)
    chat(mother, web_inbox, '55555@lid', at: 3.days.ago)
    mother
  end

  it 'H2c-widget never delivers the child reminder to a widget visitor merged into the mother by email', :aggregate_failures do
    mother = lid_mother('mother.h2c@example.com')
    default_plan!('Child visit reminder H2CW')
    widget_headers = stranger_widget_session!('mother.h2c@example.com')

    appointment = book!(mother)

    expect(Reminders::PatientSubjectGuard.notification_route(appointment.reload)).to be_unroutable
    expect_fail_closed(appointment.reminders.sole)
    expect(visible_in_widget?(widget_headers, 'Child visit reminder H2CW')).to be(false)
  end

  it 'H2c-api never delivers the child reminder to a public API contact attached to the mother by email', :aggregate_failures do
    mother = lid_mother('mother.h2a@example.com')
    default_plan!('Child visit reminder H2CA')
    post "/public/api/v1/inboxes/#{api_channel.identifier}/contacts", params: { email: 'mother.h2a@example.com', name: 'Stranger' }, as: :json
    source_id = response.parsed_body['source_id']
    post "/public/api/v1/inboxes/#{api_channel.identifier}/contacts/#{source_id}/conversations", as: :json
    stranger_conversation_id = response.parsed_body['id']

    appointment = book!(mother)

    expect_fail_closed(appointment.reminders.sole)
    get "/public/api/v1/inboxes/#{api_channel.identifier}/contacts/#{source_id}/conversations/#{stranger_conversation_id}/messages", as: :json
    expect(response.body).not_to include('Child visit reminder H2CA')
  end

  it 'H2c-holder delivers the child reminder booked from the father page only in the mother WhatsApp chat on the number',
     :aggregate_failures do
    mother = create(:contact, account: account, name: 'Mother', phone_number: family, email: 'mother.h2h@example.com')
    _mother_ci, mother_chat = chat(mother, web_inbox, family_digits, at: 3.days.ago)
    father = create(:contact, account: account, name: 'Father', phone_number: '+77000000031')
    default_plan!('Child visit reminder H2CH')
    widget_headers = stranger_widget_session!('mother.h2h@example.com')

    appointment = book!(father)
    route = Reminders::PatientSubjectGuard.notification_route(appointment.reload)
    touch = force_run!(appointment.reminders.sole)

    expect(route).to have_attributes(contact: mother, conversation: mother_chat, kind: :holder)
    expect(touch).to be_completed
    expect(touch_messages(touch).pluck(:conversation_id)).to eq([mother_chat.id])
    expect(visible_in_widget?(widget_headers, 'Child visit reminder H2CH')).to be(false)
  end

  it 'H2c-import fails closed for an imported appointment of a hidden-number share', :aggregate_failures do
    mother = lid_mother('mother.h2i@example.com')
    card = create(:contact, account: account, name: 'Child', phone_number: nil,
                            custom_attributes: { Contacts::SharedPhone::CARD_KEY => true, 'medelement_patient_code' => 'child-1',
                                                 'secondary_phones' => [family], Contacts::SharedPhone::SHARED_PHONE_KEY => family,
                                                 Contacts::SharedPhone::SHARED_OWNER_KEY => mother.id,
                                                 Contacts::SharedPhone::SHARED_VIA_KEY => Contacts::SharedPhone::VIA_BOOKING_CHAT })
    default_plan!('Child visit reminder H2CI')
    widget_headers = stranger_widget_session!('mother.h2i@example.com')
    delivery_contact = Integrations::Medelement::PatientContactBinding.delivery_contact(card)
    appointment = create(:scheduling_appointment, account: account, resource: resource, contact: delivery_contact, conversation: nil,
                                                  patient_contact: card, source: 'medelement', starts_at: booking_day,
                                                  ends_at: booking_day + 30.minutes)
    Reminders::DefaultPlanService.new(account: account, remindable: appointment).perform

    expect(delivery_contact).to eq(mother)
    expect_fail_closed(appointment.reload.reminders.sole)
    expect(visible_in_widget?(widget_headers, 'Child visit reminder H2CI')).to be(false)
  end
end
