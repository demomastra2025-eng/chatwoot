require 'rails_helper'

RSpec.describe Captain::Tools::CancelAppointmentTool, type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:tool) { described_class.new(assistant) }

  before do
    account.enable_features!('scheduling')
  end

  it 'returns normalized cancel_appointment payload' do
    resource = create(:scheduling_resource, account: account)
    contact = create(:contact, account: account)
    scheduling_service = create(:scheduling_service, account: account)
    conversation = create(:conversation, account: account, contact: contact)
    appointment = create(:scheduling_appointment, account: account, resource: resource, contact: contact, service: scheduling_service,
                                                  conversation_id: conversation.id)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, appointment: { id: appointment.id } })

    payload = JSON.parse(tool.perform(tool_context))

    expect(payload).to include('success' => true, 'appointment_id' => appointment.id, 'status' => 'cancelled')
    expect(payload.keys).to match_array(%w[success appointment_id doctor_name local_date local_time status])
  end

  it 're-reads the explicitly selected cancelled appointment without cancelling another active appointment' do
    resource = create(:scheduling_resource, account: account)
    conversation = create(:conversation, account: account)
    selected = create(:scheduling_appointment, account: account, resource: resource, conversation: conversation,
                                             contact: conversation.contact, status: 'cancelled')
    other = create(:scheduling_appointment, account: account, resource: resource, conversation: conversation,
                                          contact: conversation.contact, status: 'scheduled')
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id } })

    payload = JSON.parse(tool.perform(tool_context, appointment_id: selected.id))

    expect(payload).to include('appointment_id' => selected.id, 'status' => 'cancelled')
    expect(other.reload.status).to eq('scheduled')
  end

  it 'does not cancel any appointment when an explicit appointment ID is unavailable' do
    resource = create(:scheduling_resource, account: account)
    conversation = create(:conversation, account: account)
    appointment = create(:scheduling_appointment, account: account, resource: resource, conversation: conversation)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id } })

    result = tool.perform(tool_context, appointment_id: appointment.id + 1_000_000)

    expect(JSON.parse(result)).to eq('success' => false, 'reason' => 'not_found')
    expect(appointment.reload.status).to eq('scheduled')
  end

  it 'requires an appointment ID when the conversation has multiple appointments' do
    resource = create(:scheduling_resource, account: account)
    conversation = create(:conversation, account: account)
    appointments = create_list(:scheduling_appointment, 2, account: account, resource: resource, conversation: conversation)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id } })

    result = tool.perform(tool_context)

    expect(JSON.parse(result)).to eq('success' => false, 'reason' => 'validation_error')
    expect(appointments.map { |appointment| appointment.reload.status }).to all(eq('scheduled'))
  end

  it 'does not cancel an imported Medelement appointment' do
    resource = create(:scheduling_resource, account: account)
    contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: contact)
    appointment = create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      contact: contact,
      conversation: conversation,
      source: 'medelement',
      external_ref: 'medelement:reception:captain-cancel'
    )
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, appointment: { id: appointment.id } })

    result = tool.perform(tool_context)

    expect(JSON.parse(result)).to eq('success' => false, 'reason' => 'validation_error')
    expect(appointment.reload.status).to eq('scheduled')
  end

  it 'returns the exact remove command receipt for a provider-backed appointment' do
    settings = attributes_for(:integrations_hook, :medelement)[:settings].merge(
      'write_enabled' => true, 'remove_reception_on_cancel' => true
    )
    create(:integrations_hook, :medelement, account: account, settings: settings)
    resource = create(:scheduling_resource, account: account, custom_attributes: {
                        'medelement_specialist_code' => 'specialist-1',
                        'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
                      })
    contact = create(:contact, account: account, name: 'Aruzhan', last_name: 'Testova', phone_number: '+77011234567')
    conversation = create(:conversation, account: account, contact: contact)
    appointment = create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      contact: contact,
      conversation: conversation,
      external_ref: 'medelement:reception:reception-1',
      custom_attributes: {
        'medelement_reception_code' => 'reception-1', 'medelement_cabinet_code' => 'cabinet-1',
        Integrations::Medelement::AppointmentProviderStatus::ATTRIBUTE_KEY => Integrations::Medelement::AppointmentProviderStatus::SUCCEEDED
      }
    )
    other = create(:scheduling_appointment, account: account, resource: resource, contact: contact, conversation: conversation)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, appointment: { id: appointment.id } })

    result = tool.perform(tool_context, appointment_id: appointment.id)
    raise result if result.start_with?('ERROR:')

    payload = JSON.parse(result)

    expect(payload).to include('success' => false, 'appointment_id' => appointment.id, 'status' => 'pending_provider_confirmation',
                              'provider_confirmed' => false, 'reason' => 'pending_provider_confirmation')
    expect(payload.keys).to match_array(%w[success appointment_id doctor_name local_date local_time status reason provider_confirmed])
    command = Integrations::Medelement::ProviderCommand.find_by!(appointment_id: appointment.id, operation: 'remove_reception')
    expect(command.request_snapshot.dig('actor', 'type')).to eq('Captain::Assistant')
    expect(other.reload.status).to eq('scheduled')
  end

  it 'cancels a provider-backed appointment only in OneLink while the integration keeps receptions' do
    settings = attributes_for(:integrations_hook, :medelement)[:settings].merge('write_enabled' => true)
    create(:integrations_hook, :medelement, account: account, settings: settings)
    resource = create(:scheduling_resource, account: account, custom_attributes: {
                        'medelement_specialist_code' => 'specialist-1',
                        'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
                      })
    contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: contact)
    appointment = create(
      :scheduling_appointment,
      account: account, resource: resource, contact: contact, conversation: conversation,
      external_ref: 'medelement:reception:reception-1',
      custom_attributes: {
        'medelement_reception_code' => 'reception-1', 'medelement_cabinet_code' => 'cabinet-1',
        Integrations::Medelement::AppointmentProviderStatus::ATTRIBUTE_KEY => Integrations::Medelement::AppointmentProviderStatus::SUCCEEDED
      }
    )
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id } })

    payload = JSON.parse(tool.perform(tool_context, appointment_id: appointment.id))

    expect(payload).to include('appointment_id' => appointment.id, 'status' => 'cancelled_local_only',
                              'cancellation_scope' => 'onelink_only', 'provider_reception_active' => true)
    expect(payload.keys).to match_array(%w[success appointment_id doctor_name local_date local_time status cancellation_scope provider_reception_active])
    expect(appointment.reload.custom_attributes[Integrations::Medelement::LocalCancellation::MARKER_KEY]).to include(
      'actor' => { 'type' => 'Captain::Assistant', 'id' => assistant.id }
    )
    expect(Integrations::Medelement::ProviderCommand.where(appointment_id: appointment.id)).to be_empty
  end

  it 'does not cancel an unverified provider booking and returns the typed verification error' do
    settings = attributes_for(:integrations_hook, :medelement)[:settings].merge(
      'write_enabled' => true, 'remove_reception_on_cancel' => true
    )
    create(:integrations_hook, :medelement, account: account, settings: settings)
    resource = create(:scheduling_resource, account: account, custom_attributes: {
                        'medelement_specialist_code' => 'specialist-1',
                        'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
                      })
    contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: contact)
    appointment = create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      contact: contact,
      conversation: conversation,
      external_ref: 'medelement:reception:reception-1',
      custom_attributes: { 'medelement_reception_code' => 'reception-1', 'medelement_cabinet_code' => 'cabinet-1' }
    )
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id } })

    result = tool.perform(tool_context, appointment_id: appointment.id)

    expect(JSON.parse(result)).to eq('success' => false, 'reason' => 'staff_will_help')
    expect(appointment.reload.status).to eq('scheduled')
    expect(Integrations::Medelement::ProviderCommand.where(appointment_id: appointment.id, operation: 'remove_reception')).to be_empty
  end
end
