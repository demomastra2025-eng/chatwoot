require 'rails_helper'

RSpec.describe Captain::Tools::Agent::AccountToolAdapter do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, account: account, name: 'Patient Alpha') }
  let(:other_contact) { create(:contact, account: account, name: 'Patient Beta') }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:tool_context) { Struct.new(:state, :context).new({ conversation: { id: conversation.id } }, {}) }
  let(:missing_id) { 2_147_483_647 }
  let(:neutral_failure) { Captain::Tools::Agent::PatientScope::FAILURE }

  before do
    account.enable_features!('scheduling', 'crm_deals')
  end

  def call_tool(tool_id, **arguments)
    described_class.new(assistant, tool_id: tool_id).execute(tool_context, **arguments)
  end

  it 'reads an own appointment and gives identical failures for same-account, cross-account and absent ids' do
    own = create(:scheduling_appointment, account: account, contact: contact, conversation: conversation)
    foreign = create(:scheduling_appointment, account: account, contact: other_contact)
    other_account = create(:account)
    cross_account = create(:scheduling_appointment, account: other_account)

    own_payload = JSON.parse(call_tool('get_appointment', appointment_id: own.id))
    expect(own_payload).to include('success' => true, 'appointment_id' => own.id)
    expect(own_payload.keys).to match_array(%w[success appointment_id doctor_name local_date local_time status])
    [foreign.id, cross_account.id, missing_id].each do |id|
      expect(JSON.parse(call_tool('get_appointment', appointment_id: id))).to eq('success' => false, 'reason' => 'not_found')
    end
  end

  it 'limits appointment searches to the conversation contact despite a text query or contact filter' do
    own = create(:scheduling_appointment, account: account, contact: contact, conversation: conversation, client_name: 'Patient Alpha')
    other = create(:scheduling_appointment, account: account, contact: other_contact, client_name: 'Patient Beta')

    search = JSON.parse(call_tool('search_appointments'))
    expect(search.fetch('appointments').pluck('appointment_id')).to eq([own.id])
    expect(search.keys).to match_array(%w[success appointments has_more])
    expect(JSON.parse(call_tool('search_appointments', client_name: 'Patient Beta')).fetch('appointments')).to be_empty
    expect(JSON.parse(call_tool('search_appointments', contact_id: other_contact.id))).to eq('success' => false, 'reason' => 'not_found')
    expect(JSON.parse(call_tool('search_appointments', contact_id: missing_id))).to eq('success' => false, 'reason' => 'not_found')
    expect(other.id).not_to eq(own.id)
  end

  it 'keeps provider status neutral even for an own command' do
    own = create(:scheduling_appointment, account: account, contact: contact, conversation: conversation)
    foreign = create(:scheduling_appointment, account: account, contact: other_contact)
    own_command = provider_command_for(own)
    foreign_command = provider_command_for(foreign)

    [own_command.id, foreign_command.id, missing_id].each do |id|
      expect(JSON.parse(call_tool('get_appointment_provider_status', provider_command_id: id)))
        .to eq('success' => false, 'reason' => 'staff_will_help')
    end
  end

  it 'allows a specifically identified family appointment without granting the rest of their history' do
    resource = create(:scheduling_resource, account: account)
    selected = create(:scheduling_appointment, account: account, contact: other_contact, resource: resource,
                                             client_name: 'Patient Beta', starts_at: 1.day.from_now.change(hour: 10))
    historical = create(:scheduling_appointment, account: account, contact: other_contact,
                                               client_name: 'Patient Beta', starts_at: 2.days.ago)
    lookup = JSON.parse(call_tool('search_appointments', client_name: 'Patient Beta', resource_id: resource.id,
                                                       from: selected.starts_at.beginning_of_day.iso8601))
    expect(lookup.fetch('appointments').pluck('appointment_id')).to eq([selected.id])
    token = lookup.fetch('appointments').first.fetch('appointment_access_token')

    expect(JSON.parse(call_tool('get_appointment', appointment_id: selected.id, appointment_access_token: token)))
      .to include('success' => true, 'appointment_id' => selected.id)
    expect(JSON.parse(call_tool('get_appointment', appointment_id: historical.id, appointment_access_token: token)))
      .to eq('success' => false, 'reason' => 'not_found')
    expect(JSON.parse(call_tool('get_contact', contact_id: other_contact.id)))
      .to include('error' => 'Record is not available')
  end

  it 'restricts conversation search to the current contact' do
    foreign_conversation = create(:conversation, account: account, contact: other_contact)

    payload = JSON.parse(call_tool('search_conversations'))

    expect(payload.fetch('conversations').pluck('id')).to eq([conversation.id])
    expect(call_tool('search_conversations', contact_id: other_contact.id)).to eq(neutral_failure)
    expect(payload.to_json).not_to include(foreign_conversation.contact.name)
  end

  it 'reads only the current contact even when another contact id or name is supplied' do
    expect(JSON.parse(call_tool('get_contact', contact_id: contact.id)).dig('contact', 'id')).to eq(contact.id)
    expect(call_tool('get_contact', contact_id: other_contact.id)).to eq(neutral_failure)
    expect(call_tool('get_contact', contact_id: missing_id)).to eq(neutral_failure)

    expect(JSON.parse(call_tool('search_contacts')).fetch('contacts').pluck('id')).to eq([contact.id])
    expect(JSON.parse(call_tool('search_contacts', name: other_contact.name)).fetch('contacts')).to be_empty
  end

  it 'scopes deal lookup and text search to own deal contacts' do
    own = create(:crm_deal, account: account, title: 'Own booking')
    foreign = create(:crm_deal, account: account, title: 'Private booking')
    create(:crm_deal_contact, account: account, deal: own, contact: contact, primary: true)
    create(:crm_deal_contact, account: account, deal: foreign, contact: other_contact, primary: true)
    cross_account = create(:crm_deal, account: create(:account))

    expect(JSON.parse(call_tool('get_deal', deal_id: own.id)).dig('deal', 'id')).to eq(own.id)
    [foreign.id, cross_account.id, missing_id].each do |id|
      expect(call_tool('get_deal', deal_id: id)).to eq(neutral_failure)
    end
    expect(JSON.parse(call_tool('search_deals')).fetch('deals').pluck('id')).to eq([own.id])
    expect(JSON.parse(call_tool('search_deals', query: 'Private booking')).fetch('deals')).to be_empty
    expect(call_tool('search_deals', contact_id: other_contact.id)).to eq(neutral_failure)
    expect(call_tool('search_deals', contact_id: missing_id)).to eq(neutral_failure)
  end

  it 'does not return other deal contacts from a deal linked to the current contact' do
    deal = create(:crm_deal, account: account)
    create(:crm_deal_contact, account: account, deal: deal, contact: other_contact, primary: true)
    create(:crm_deal_contact, account: account, deal: deal, contact: contact)

    payload = JSON.parse(call_tool('get_deal', deal_id: deal.id)).fetch('deal')

    expect(payload).not_to have_key('deal_contacts')
    expect(payload).not_to have_key('primary_contact')
    expect(payload).not_to have_key('primary_contact_id')
    expect(payload.to_json).not_to include(other_contact.name)
  end

  it 'denies account-wide task search at call time and records the denied attempt' do
    account.enable_features!('crm_tasks')
    events = []
    subscription = ActiveSupport::Notifications.subscribe('llm.captain.tool.denied') do |_name, _start, _finish, _unique_id, payload|
      events << payload
    end

    expect(call_tool('search_tasks')).to eq(neutral_failure)
    expect(events.last).to include('tool_name' => 'search_tasks', 'id_kind' => 'task', 'outcome' => 'denied')
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  it 'denies a message to another contact conversation with the neutral result' do
    foreign_conversation = create(:conversation, account: account, contact: other_contact)

    result = call_tool(
      'send_message_to_conversation', conversation_id: foreign_conversation.display_id,
                                      content: 'Private note', private_note: true
    )

    expect(result).to eq(neutral_failure)
    expect(foreign_conversation.messages.where(content: 'Private note')).to be_empty
  end

  it 'keeps a message to the current patient conversation available' do
    create(:captain_inbox, inbox: conversation.inbox, captain_assistant: assistant)

    result = call_tool(
      'send_message_to_conversation', conversation_id: conversation.display_id,
                                      content: 'Own private note', private_note: true
    )

    expect(JSON.parse(result).dig('message', 'content')).to eq('Own private note')
    expect(conversation.messages.where(content: 'Own private note')).to exist
  end

  it 'records a minimal denied event without the supplied id or patient details' do
    foreign = create(:scheduling_appointment, account: account, contact: other_contact)
    events = []
    subscription = ActiveSupport::Notifications.subscribe('llm.captain.tool.denied') do |_name, _start, _finish, _unique_id, payload|
      events << payload
    end

    expect(JSON.parse(call_tool('get_appointment', appointment_id: foreign.id))).to eq('success' => false, 'reason' => 'not_found')

    event = events.last
    expect(event).to include(
      'tool_name' => 'get_appointment', 'account_id' => account.id,
      'conversation_id' => conversation.id, 'contact_id' => contact.id,
      'id_kind' => 'appointment', 'outcome' => 'denied'
    )
    expect(event).not_to have_key('appointment_id')
    expect(event).not_to have_key('supplied_id')
    expect(event).not_to have_key('phone_number')
    expect(event.to_json).not_to include(other_contact.name)

    expect do
      Llm::Monitoring::EventRecorder.record_notification(
        event_name: 'llm.captain.tool.denied', started_at: Time.current, finished_at: Time.current, payload: event
      )
    end.to change(LlmEvent, :count).by(1)
    stored_event = LlmEvent.order(:id).last
    expect(stored_event).to have_attributes(
      tool_name: 'get_appointment', account_id: account.id, conversation_id: conversation.id
    )
    expect(stored_event.payload).to include('contact_id' => contact.id, 'id_kind' => 'appointment', 'outcome' => 'denied')
    expect(stored_event.payload.to_json).not_to include(other_contact.name)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  it 'keeps staff Copilot account search available' do
    staff = create(:user, account: account)
    create(:scheduling_appointment, account: account, contact: contact)
    foreign = create(:scheduling_appointment, account: account, contact: other_contact)
    service = Captain::Tools::Copilot::SearchAppointmentsService.new(assistant, user: staff)

    expect(JSON.parse(service.execute).fetch('appointments').pluck('id')).to include(foreign.id)
  end

  def provider_command_for(appointment)
    Integrations::Medelement::ProviderCommand.create!(
      account: appointment.account, appointment: appointment, contact: appointment.contact,
      operation: 'create_reception', status: 'processing', idempotency_key: SecureRandom.uuid,
      company_cabinet_code: 'cabinet-1', provider_patient_code: 'patient-1',
      desired_starts_at: appointment.starts_at, desired_ends_at: appointment.ends_at,
      execution_state: {
        'request_fingerprint' => SecureRandom.uuid,
        'dispatch_identity' => SecureRandom.uuid,
        'request_snapshot' => {
          'actor' => { 'type' => 'Captain::Assistant', 'id' => assistant.id },
          'account_id' => appointment.account_id,
          'appointment_id' => appointment.id,
          'contact_id' => appointment.contact_id,
          'conversation_id' => conversation.id,
          'reception' => {
            'resource_id' => appointment.resource_id,
            'destination_starts_at' => appointment.starts_at.iso8601,
            'destination_ends_at' => appointment.ends_at.iso8601,
            'nomenclature_codes' => []
          }
        }
      }
    )
  end
end
