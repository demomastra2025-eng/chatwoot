require 'rails_helper'

# The agent cancels a MedElement reception. The tool answers only after MedElement answered the removal: the provider's OK is
# a success even while a cached read still shows the reception as active; a rejection, an ambiguous answer or silence is a
# technical failure. Nothing here ever touches the conversation.
RSpec.describe Captain::Tools::CancelAppointmentTool, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(Time.utc(2026, 4, 19, 12)) { example.run } }

  let(:account) { create(:account, locale: 'ru').tap { |record| record.enable_features!('scheduling') } }
  let(:assistant) { create(:captain_assistant, account: account, usage_mode: 'external_agent') }
  let(:tool) { described_class.new(assistant) }
  let(:status) { Integrations::Medelement::AppointmentProviderStatus }
  let(:starts_at) { Time.zone.parse('2026-04-20 09:00:00 +0500') }
  let(:ends_at) { Time.zone.parse('2026-04-20 09:30:00 +0500') }
  let(:contact) do
    create(:contact, account: account, name: 'Aruzhan', last_name: 'Testova', phone_number: '+77011234567',
                     custom_attributes: { 'medelement_patient_code' => 'patient-1' })
  end
  let(:conversation) { create(:conversation, account: account, contact: contact, status: :pending) }
  let(:resource) do
    create(:scheduling_resource, account: account, timezone: 'Asia/Almaty', custom_attributes: {
             'medelement_specialist_code' => 'specialist-1', 'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
           })
  end
  let!(:appointment) do
    create(:scheduling_appointment, account: account, resource: resource, contact: contact, conversation: conversation, service: nil,
                                    external_ref: 'medelement:reception:reception-1', starts_at: starts_at, ends_at: ends_at,
                                    custom_attributes: { 'medelement_reception_code' => 'reception-1', 'medelement_cabinet_code' => 'cabinet-1',
                                                         status::ATTRIBUTE_KEY => status::SUCCEEDED })
  end
  let(:client) { instance_double(Integrations::Medelement::Client) }
  let(:tool_context) { Struct.new(:state).new({ conversation: { id: conversation.id }, appointment: { id: appointment.id } }) }
  let(:execute_commands_inline) { true }
  let(:active_reception) do
    {
      'RECEPTION_CODE' => 'reception-1', 'PROFILE_CODE' => 'patient-1', 'SPECIALIST_CODE' => 'specialist-1',
      'COMPANY_CABINET_CODE' => 'cabinet-1', 'STARTTIME' => starts_at.in_time_zone('Asia/Almaty').strftime('%d.%m.%Y %H:%M:%S'),
      'ENDTIME' => ends_at.in_time_zone('Asia/Almaty').strftime('%d.%m.%Y %H:%M:%S'), 'ACTIVE' => 1, 'REMOVED' => 0, 'SERVICES' => []
    }
  end

  before do
    create(:captain_inbox, inbox: conversation.inbox, captain_assistant: assistant)
    create(:integrations_hook, :medelement, account: account,
                                            settings: attributes_for(:integrations_hook, :medelement)[:settings].merge(
                                              'write_enabled' => true, 'remove_reception_on_cancel' => true
                                            ))
    allow(Integrations::Medelement::CronScheduleService).to receive(:new)
      .and_return(instance_double(Integrations::Medelement::CronScheduleService, sync!: true))
    allow(Integrations::Medelement::Client).to receive(:new).and_return(client)
    # A cached read server keeps showing the reception as active.
    allow(client).to receive(:get_reception).and_return(active_reception)
    allow(client).to receive(:get_receptions).and_return([{ 'RECEPTION_CODE' => 'reception-1', 'COMPANY_CABINET_CODE' => 'cabinet-1', 'PAID' => 'not' }])
    allow(Captain::Tools::ProviderWriteWait).to receive(:timeout_seconds).and_return(0.4)
    allow(Integrations::Medelement::ProviderCommandJob).to receive(:perform_later) do |command_id|
      next unless execute_commands_inline

      Integrations::Medelement::ProviderCommands::Executor.new(command: Integrations::Medelement::ProviderCommand.find(command_id)).perform
    end
  end

  def remove_command
    Integrations::Medelement::ProviderCommand.find_by!(appointment_id: appointment.id, operation: 'remove_reception')
  end

  def expect_conversation_untouched
    expect(conversation.messages.outgoing).to be_empty
    expect(conversation.reload.status).to eq('pending')
    expect(conversation.current_captain_control_state).not_to eq('human')
  end

  it 'reports a cancellation as soon as MedElement answers OK, although its read still shows the reception active' do
    allow(client).to receive(:remove_reception).and_return({})

    payload = JSON.parse(tool.perform(tool_context, appointment_id: appointment.id))

    expect(payload).to include('success' => true, 'status' => 'cancelled', 'provider_confirmed' => true,
                               'provider_confirmation_operation' => 'remove_reception')
    expect(payload).not_to include('error_class')
    expect(remove_command).to be_succeeded
    expect(appointment.reload).to have_attributes(status: 'cancelled', payment_status: 'cancelled')
    expect(client).to have_received(:remove_reception).once
    expect(client).to have_received(:get_reception).once
    expect_conversation_untouched
  end

  it 'reports an explicit MedElement rejection as a technical failure and keeps the appointment' do
    allow(client).to receive(:remove_reception).and_raise(Integrations::Medelement::Client::ApiError.new('rejected', status: 422))

    payload = JSON.parse(tool.perform(tool_context, appointment_id: appointment.id))

    expect(payload).to include('success' => false, 'provider_confirmed' => false, 'error_class' => 'technical',
                               'status' => 'provider_confirmation_failed')
    expect(remove_command).to be_failed
    expect(appointment.reload.status).to eq('scheduled')
    expect_conversation_untouched
  end

  it 'reports an ambiguous MedElement answer as a technical failure that is still unconfirmed' do
    allow(client).to receive(:remove_reception).and_raise(
      Integrations::Medelement::Client::ApiError.new('timeout', status: 503, ambiguous: true)
    )

    payload = JSON.parse(tool.perform(tool_context, appointment_id: appointment.id))

    expect(payload).to include('success' => false, 'provider_confirmed' => false, 'error_class' => 'technical')
    expect(remove_command).to be_reconciliation_required
    expect(appointment.reload.status).to eq('scheduled')
    expect_conversation_untouched
  end

  context 'when MedElement does not answer in time' do
    let(:execute_commands_inline) { false }

    it 'reports a technical failure, and the late OK only updates the calendar' do
      allow(client).to receive(:remove_reception).and_return({})

      payload = JSON.parse(tool.perform(tool_context, appointment_id: appointment.id))

      expect(payload).to include('success' => false, 'status' => 'pending_provider_confirmation', 'error_class' => 'technical')
      expect(appointment.reload.status).to eq('scheduled')

      Integrations::Medelement::ProviderCommands::Executor.new(command: remove_command).perform

      expect(remove_command).to be_succeeded
      expect(appointment.reload.status).to eq('cancelled')
      expect_conversation_untouched
    end
  end
end
