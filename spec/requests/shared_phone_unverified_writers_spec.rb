require 'rails_helper'

# sc8rv1 round 2 (H2b, LF1-LF3): unverified writers (widget identify, public API contact create, public lead forms) never
# receive a patient's reminders through a family number, never take a reserved number, never file a chat under a patient
# card and never write server-owned attributes. Synthetic data only.
RSpec.describe 'Family numbers and unverified public writers', type: :request do
  around do |example|
    with_modified_env('EVOLUTION_API_URL' => 'https://evolution.example.com', 'EVOLUTION_API_KEY' => 'test-api-key',
                      'FRONTEND_URL' => 'https://app.example.com') { example.run }
  end

  let(:family) { '+77000000009' }
  let(:child_iin) { '940720300129' }
  let(:account) { create(:account, limits: { non_web_inboxes: ChatwootApp.max_limit }) }
  let(:resource) { create(:scheduling_resource, account: account, timezone: 'Asia/Almaty') }
  let(:service) { create(:scheduling_service, account: account, base_price: 20_000) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:booking_day) do
    timezone = ActiveSupport::TimeZone['Asia/Almaty']
    date = timezone.today.next_occurring(:monday)
    timezone.local(date.year, date.month, date.day, 10, 0, 0)
  end
  let(:widget) { create(:channel_widget, account: account) }
  let(:api_channel) { create(:channel_api, account: account, webhook_url: nil) }
  let(:web_inbox) { create(:channel_whatsapp_web, account: account).inbox }
  let(:mother) { create(:contact, account: account, name: 'Mother', phone_number: family) }
  let(:father) { create(:contact, account: account, name: 'Father', phone_number: '+77000000031') }

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
    fresh = Integrations::Medelement::AppointmentFreshnessVerifier::Result.new(status: 'fresh', reason: nil, checked_at: Time.current,
                                                                               command_id: nil, command_status: nil)
    allow_any_instance_of(Integrations::Medelement::AppointmentFreshnessVerifier).to receive(:perform).and_return(fresh) # rubocop:disable RSpec/AnyInstance
  end

  def chat(contact, inbox, source_id = nil)
    attributes = { contact: contact, inbox: inbox, source_id: source_id }.compact
    contact_inbox = create(:contact_inbox, **attributes)
    conversation = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
    create(:message, account: account, inbox: inbox, conversation: conversation, sender: contact, message_type: :incoming)
    [contact_inbox, conversation]
  end

  def booking_params(owner, conversation)
    { resource_id: resource.id, contact_id: owner.id, conversation_id: conversation.id, service_id: service.id,
      starts_at: booking_day.iso8601, ends_at: (booking_day + 30.minutes).iso8601, client_first_name: 'Child', client_last_name: 'Patient',
      client_name: 'Child Patient', client_phone: family, client_identifier: child_iin, service_amount: 20_000,
      custom_attributes: { medelement_cabinet_code: 'cabinet-1' } }
  end

  def book!(owner, conversation)
    post "/api/v1/accounts/#{account.id}/scheduling/appointments", params: booking_params(owner, conversation),
                                                                   headers: agent.create_new_auth_token, as: :json
    expect(response).to have_http_status(:success)
    Scheduling::Appointment.find(response.parsed_body.dig('payload', 'id'))
  end

  def run_touch!(appointment, booking, body)
    touch = create(:reminder, account: account, touch_conversation: booking, conversation: booking, remindable: appointment,
                              status: :processing, body: body, scheduled_at: 1.minute.ago)
    Reminders::ExecuteService.new(reminder: touch).perform
    if touch.reload.pending?
      touch.update_columns(status: Reminder.statuses[:processing], processing_started_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
      Reminders::ExecuteService.new(reminder: touch.reload).perform
    end
    Message.outgoing.where(account_id: account.id).where("additional_attributes ->> 'touch_id' = ?", touch.id.to_s).to_a
  end

  describe 'H2b a family number sent by an unverified writer' do
    it 'H2b a widget visitor that types the mother number is not merged into her and never reads the child reminder', :aggregate_failures do
      _father_ci, booking = chat(father, widget.inbox)
      mother
      appointment = book!(father, booking)
      expect(appointment.patient_contact.custom_attributes[Contacts::SharedPhone::SHARED_OWNER_KEY]).to eq(mother.id)
      visitor = create(:contact, account: account, name: 'Stranger')
      visitor_ci = create(:contact_inbox, contact: visitor, inbox: widget.inbox)
      token = Widget::TokenService.new(payload: { source_id: visitor_ci.source_id, inbox_id: widget.inbox.id }).generate_token

      patch '/api/v1/widget/contact', params: { website_token: widget.website_token, phone_number: family },
                                      headers: { 'X-Auth-Token' => token }, as: :json
      expect(visitor_ci.reload.contact_id).to eq(visitor.id)
      expect(visitor.reload.phone_number).to be_nil
      post '/api/v1/widget/conversations', params: { website_token: widget.website_token, message: { content: 'hello' } },
                                           headers: { 'X-Auth-Token' => token }, as: :json

      sent = run_touch!(appointment, booking, 'Child visit reminder H2b')

      expect(sent.map(&:conversation_id)).to eq([booking.id])
      get '/api/v1/widget/messages', params: { website_token: widget.website_token }, headers: { 'X-Auth-Token' => token }, as: :json
      expect(response.body).not_to include('Child visit reminder H2b')
    end

    it 'H2b-api a public API client that sends the mother number is not attached to her and never reads the reminder', :aggregate_failures do
      _father_ci, booking = chat(father, api_channel.inbox)
      mother
      appointment = book!(father, booking)

      post "/public/api/v1/inboxes/#{api_channel.identifier}/contacts", params: { phone_number: family, name: 'Stranger' }, as: :json
      source_id = response.parsed_body['source_id']
      stranger_ci = api_channel.inbox.contact_inboxes.find_by(source_id: source_id)
      expect(stranger_ci.contact_id).not_to eq(mother.id)
      expect(stranger_ci.contact.phone_number).to be_nil
      post "/public/api/v1/inboxes/#{api_channel.identifier}/contacts/#{source_id}/conversations", as: :json
      stranger_conversation_id = response.parsed_body['id']

      sent = run_touch!(appointment, booking, 'Child visit reminder H2b-api')

      expect(sent.map(&:conversation_id)).to eq([booking.id])
      get "/public/api/v1/inboxes/#{api_channel.identifier}/contacts/#{source_id}/conversations/#{stranger_conversation_id}/messages", as: :json
      expect(response.body).not_to include('Child visit reminder H2b-api')
    end

    it 'H2b-benign an old widget chat of the mother does not take the reminder away from the father booking chat', :aggregate_failures do
      _mother_ci, mother_old = chat(mother, widget.inbox)
      mother_old.update!(status: :resolved)
      _father_ci, booking = chat(father, widget.inbox)
      appointment = book!(father, booking)
      conversations_before = Conversation.where(account_id: account.id).count

      sent = run_touch!(appointment, booking, 'Child visit reminder benign')

      expect(sent.map(&:conversation_id)).to eq([booking.id])
      expect(Conversation.where(account_id: account.id).count).to eq(conversations_before)
      expect(mother_old.reload).to be_resolved
    end
  end

  describe 'public lead forms' do
    let(:lead_form) { create(:lead_form, account: account, inbox: widget.inbox) }

    def submit_lead!(phone:, name: 'Lead Person', contact: {}, custom: nil)
      params = { field_values: { full_name: name, phone_number: phone }, contact: contact }
      params[:contact_custom_attributes] = custom if custom
      post "/api/v1/lead_forms/#{lead_form.public_token}/submissions", params: params, as: :json
      expect(response).to have_http_status(:created)
      LeadSubmission.find(response.parsed_body.dig('payload', 'id')).contact
    end

    def hidden_booking
      owner = create(:contact, account: account, name: 'Mother', phone_number: nil, identifier: 'whatsapp_web:55555@lid')
      _owner_ci, conversation = chat(owner, web_inbox, '55555@lid')
      [owner, conversation, book!(owner, conversation)]
    end

    it 'LF1 never takes the number reserved for a hidden booking chat; the reveal keeps the mother', :aggregate_failures do
      owner, conversation, = hidden_booking
      lead = submit_lead!(phone: family, name: 'Lead Stranger')

      expect(lead.phone_number).to be_nil
      WhatsappWeb::ContactSyncService.new(channel: web_inbox.channel, contact_payload: { remoteJid: '77000000009@s.whatsapp.net',
                                                                                         remoteLid: '55555@lid', pushName: 'Mother' }).perform
      expect(Contact.exists?(owner.id)).to be(true)
      expect(owner.reload.phone_number).to eq(family)
      expect(conversation.reload.contact_id).to eq(owner.id)
      expect(conversation.messages.incoming.pluck(:sender_id).uniq).to eq([owner.id])
    end

    it 'LF2 never files the lead under the patient card through its IIN identifier', :aggregate_failures do
      _owner, _conversation, appointment = hidden_booking
      card = appointment.patient_contact

      lead = submit_lead!(phone: '+77000000041', contact: { identifier: card.identifier.to_s, name: 'Anyone' })

      expect(card.identifier).to eq(child_iin)
      expect(lead.id).not_to eq(card.id)
      expect(Conversation.where(contact_id: card.id)).to be_empty
    end

    it 'LF3 never stores server-owned custom attributes (card flag, share keys, доп. номер, hint)', :aggregate_failures do
      forged = { 'medelement_patient_card' => true, 'secondary_phones' => ['+77000000051'],
                 'medelement_shared_phone_number' => '+77000000051', 'medelement_shared_phone_via' => 'booking_chat',
                 'medelement_shared_phone_hint' => { 'phone' => '+77000000051', 'reason' => 'released' }, 'favourite' => 'blue' }

      lead = submit_lead!(phone: '+77000000042', custom: forged)

      expect(lead.custom_attributes).to eq('favourite' => 'blue')
      expect(Contacts::SharedPhone.card?(lead)).to be(false)
    end
  end
end
