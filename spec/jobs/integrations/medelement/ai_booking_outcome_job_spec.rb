require 'rails_helper'

RSpec.describe Integrations::Medelement::AiBookingOutcomeJob do
  let(:account) { create(:account, locale: 'ru').tap { |record| record.enable_features!('scheduling') } }
  let(:assistant) { create(:captain_assistant, account: account, usage_mode: 'external_agent') }
  let(:contact) { create(:contact, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, status: :pending) }
  let(:resource) { create(:scheduling_resource, account: account, custom_attributes: { 'medelement_specialist_code' => 'specialist-1' }) }
  let(:appointment) { create(:scheduling_appointment, account: account, contact: contact, conversation: conversation, resource: resource) }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }
  let(:actor_type) { 'Captain::Assistant' }
  let(:operation) { 'create_reception' }
  let(:command) do
    Integrations::Medelement::ProviderCommand.create!(
      account: account, hook: hook, appointment: appointment, contact: contact,
      operation: operation, status: 'queued',
      desired_starts_at: appointment.starts_at, desired_ends_at: appointment.ends_at,
      company_cabinet_code: 'cab-1', idempotency_key: 'ai-booking-1',
      provider_reception_code: 'reception-1',
      execution_state: {
        'request_fingerprint' => 'booking-fingerprint', 'dispatch_identity' => 'booking-dispatch-1',
        'request_snapshot' => {
          'version' => 2,
          'actor' => { 'type' => actor_type, 'id' => assistant.id },
          'account_id' => account.id, 'appointment_id' => appointment.id,
          'contact_id' => contact.id, 'conversation_id' => conversation.id,
          'reception' => {
            'resource_id' => resource.id, 'destination_starts_at' => appointment.starts_at.utc.iso8601(6),
            'destination_ends_at' => appointment.ends_at.utc.iso8601(6), 'nomenclature_codes' => []
          }
        }
      }
    )
  end

  before do
    allow(described_class).to receive(:perform_later)
    create(:captain_inbox, inbox: inbox, captain_assistant: assistant)
  end

  def bind_provider_status!(value)
    status = Integrations::Medelement::AppointmentProviderStatus
    appointment.update!(custom_attributes: appointment.custom_attributes.to_h.merge(
      'medelement_cabinet_code' => 'cab-1',
      status::ATTRIBUTE_KEY => value,
      status::COMMAND_ID_KEY => command.id,
      status::COMMAND_IDEMPOTENCY_KEY => command.idempotency_key,
      status::COMMAND_FINGERPRINT_KEY => 'booking-fingerprint',
      status::COMMAND_DISPATCH_IDENTITY_KEY => 'booking-dispatch-1'
    ))
  end

  def capture_booking_fence!
    incoming = create(:message, conversation: conversation, message_type: :incoming)
    Captain::Tools::ProviderBookingHandoffService.capture_fence!(
      command: command,
      fence: {
        control_generation: conversation.current_captain_control_generation,
        status_transition_id: conversation.status_transitions.maximum(:id).to_i,
        last_message_id: incoming.id
      }
    )
  end

  it 'never sends a template or hands off a successful create with a write ID' do
    bind_provider_status!('succeeded')
    capture_booking_fence!
    command.update!(execution_state: command.execution_state.merge('write_provider_reception_code' => 'reception-1'))
    command.update!(status: 'succeeded')

    described_class.perform_now(command.id)
    expect(described_class).to have_received(:perform_later).with(command.id)
    expect(conversation.messages.outgoing).to be_empty
    expect(conversation.reload.status).to eq('pending')
    expect(command.reload.execution_state[described_class::CUSTOMER_MESSAGE_ID_KEY]).to be_nil
  end

  it 'does not enqueue an outcome when the executor saves an ID before read-back' do
    executor = Integrations::Medelement::ProviderCommands::Executor.new(command: command)
    command.update!(status: 'processing', execution_state: command.execution_state.merge('claim_token' => executor.send(:claim_token)))

    executor.send(:record_write_reference!, provider_reception_code: 'reception-2')

    expect(command.reload.provider_reception_code).to eq('reception-2')
    expect(described_class).not_to have_received(:perform_later)
  end

  it 'does not hand off while a create is still queued' do
    bind_provider_status!('pending')
    capture_booking_fence!
    described_class.perform_now(command.id)
    expect(conversation.reload.status).to eq('pending')
    expect(conversation.messages.outgoing).to be_empty
  end

  %w[failed provider_status_unknown].each do |outcome|
    it "hands off #{outcome} create once with a staff note, but never confirms it to the customer" do
      bind_provider_status!(outcome)
      capture_booking_fence!
      command.update!(status: outcome)

      described_class.perform_now(command.id)
      described_class.perform_now(command.id)

      expect(conversation.reload.status).to eq('open')
      expect(conversation.current_captain_control_state).to eq('human')
      expect(conversation.messages.outgoing.where(private: false)).to be_empty
      expect(conversation.messages.outgoing.where(private: true).count).to eq(1)
      expect(command.reload.execution_state[described_class::STAFF_NOTE_ID_KEY]).to eq(conversation.messages.outgoing.last.id)
    end
  end

  it 'hands off a succeeded create without a write-acknowledged reception ID' do
    bind_provider_status!('succeeded')
    capture_booking_fence!
    command.update!(status: 'succeeded')

    described_class.perform_now(command.id)
    expect(conversation.reload.status).to eq('open')
    expect(conversation.messages.outgoing.where(private: false)).to be_empty
  end

  it 'hands off an acknowledged create orphan once without touching a replacement booking' do
    bind_provider_status!('pending')
    capture_booking_fence!
    command.update!(provider_patient_code: 'patient-1')
    command.update!(execution_state: command.execution_state.merge('write_provider_reception_code' => 'reception-1'))
    replacement = create(:scheduling_resource, account: account)
    appointment.update!(resource: replacement)
    command.update!(status: 'succeeded')

    expect(Integrations::Medelement::ProviderCommandJob).not_to receive(:perform_later)
    described_class.perform_now(command.id)
    described_class.perform_now(command.id)

    expect(conversation.reload.status).to eq('open')
    expect(conversation.current_captain_control_state).to eq('human')
    expect(conversation.messages.outgoing.where(private: false)).to be_empty
    expect(conversation.messages.outgoing.where(private: true).count).to eq(1)
    expect(command.reload.execution_state[described_class::STAFF_NOTE_ID_KEY]).to eq(conversation.messages.outgoing.last.id)
    expect(appointment.reload.resource_id).to eq(replacement.id)
  end

  it 'notes an acknowledged orphan after human takeover without reopening it' do
    bind_provider_status!('pending')
    capture_booking_fence!
    command.update!(provider_patient_code: 'patient-1')
    command.update!(execution_state: command.execution_state.merge('write_provider_reception_code' => 'reception-1'))
    appointment.update!(resource: create(:scheduling_resource, account: account))
    conversation.update!(status: :open)
    command.update!(status: 'succeeded')

    described_class.perform_now(command.id)
    expect(conversation.reload.status).to eq('open')
    expect(conversation.messages.outgoing.where(private: true).count).to eq(1)
    expect(conversation.messages.outgoing.where(private: false)).to be_empty
  end

  it 'keeps an acknowledged orphan in the original conversation when the local appointment moves to another contact' do
    bind_provider_status!('pending')
    capture_booking_fence!
    command.update!(provider_patient_code: 'patient-1',
                    execution_state: command.execution_state.merge('write_provider_reception_code' => 'reception-1'))
    other_contact = create(:contact, account: account)
    other_conversation = create(:conversation, account: account, inbox: inbox, contact: other_contact, status: :pending)
    appointment.update!(contact: other_contact, conversation: other_conversation)
    command.update!(status: 'succeeded')

    described_class.perform_now(command.id)

    expect(conversation.reload.status).to eq('open')
    expect(conversation.messages.outgoing.where(private: true).count).to eq(1)
    expect(other_conversation.reload.status).to eq('pending')
    expect(other_conversation.messages.outgoing).to be_empty
    expect(appointment.reload).to have_attributes(contact_id: other_contact.id, conversation_id: other_conversation.id)
  end

  it 'reviews a failed read-back with an acknowledged write even when the appointment was replaced' do
    bind_provider_status!('pending')
    capture_booking_fence!
    command.update!(provider_patient_code: 'patient-1',
                    execution_state: command.execution_state.merge('write_provider_reception_code' => 'reception-1'))
    appointment.update!(resource: create(:scheduling_resource, account: account))
    command.update!(status: 'failed')

    described_class.perform_now(command.id)

    expect(conversation.reload.status).to eq('open')
    expect(conversation.messages.outgoing.where(private: true).count).to eq(1)
    expect(conversation.messages.outgoing.where(private: false)).to be_empty
  end

  it 'does not steal a later Captain run for an acknowledged orphan' do
    bind_provider_status!('pending')
    capture_booking_fence!
    command.update!(provider_patient_code: 'patient-1')
    command.update!(execution_state: command.execution_state.merge('write_provider_reception_code' => 'reception-1'))
    appointment.update!(resource: create(:scheduling_resource, account: account))
    conversation.update!(status: :open)
    conversation.prepare_captain_ai_control!
    conversation.update!(status: :pending)
    command.update!(status: 'succeeded')

    described_class.perform_now(command.id)
    expect(conversation.reload.status).to eq('pending')
    expect(conversation.messages.outgoing).to be_empty
  end

  it 'does not reassign a superseded create to the human team without a provider receipt' do
    bind_provider_status!('failed')
    capture_booking_fence!
    appointment.update!(custom_attributes: appointment.custom_attributes.merge(
      Integrations::Medelement::AppointmentProviderStatus::COMMAND_ID_KEY => command.id + 1
    ))
    command.update!(status: 'failed')

    described_class.perform_now(command.id)
    expect(conversation.reload.status).to eq('pending')
    expect(conversation.messages.outgoing).to be_empty
  end

  it 'does not reassign a failed booking after the inbox is switched to another Captain assistant' do
    bind_provider_status!('failed')
    capture_booking_fence!
    replacement = create(:captain_assistant, account: account, usage_mode: 'external_agent')
    conversation.inbox.captain_inbox.update!(captain_assistant: replacement)
    command.update!(status: 'failed')

    described_class.perform_now(command.id)
    expect(conversation.reload.status).to eq('pending')
    expect(conversation.messages.outgoing).to be_empty
  end

  it 'does not reopen after a human takes over, but makes the failed booking visible to staff' do
    bind_provider_status!('failed')
    capture_booking_fence!
    conversation.update!(status: :open)
    command.update!(status: 'failed')

    described_class.perform_now(command.id)

    expect(conversation.reload.status).to eq('open')
    expect(conversation.messages.outgoing.where(private: true).count).to eq(1)
    expect(conversation.messages.outgoing.where(private: false)).to be_empty
  end

  context 'when MedElement confirms a reschedule' do
    let(:operation) { 'move_reception' }

    it 'replies once after read-back, not just because the old reception had an ID' do
      bind_provider_status!('pending')
      command.update!(status: 'processing')
      described_class.perform_now(command.id)
      expect(conversation.messages.outgoing.where(private: false)).to be_empty

      bind_provider_status!('succeeded')
      command.update!(status: 'succeeded')
      described_class.perform_now(command.id)
      described_class.perform_now(command.id)

      expect(conversation.messages.outgoing.where(private: false).count).to eq(1)
      expect(conversation.messages.outgoing.where(private: false).last.content).to include('Ваша запись перенесена')
    end

    it 'does not send the late reschedule confirmation after a human reply' do
      bind_provider_status!('succeeded')
      command.update!(status: 'succeeded')
      conversation.update!(status: :open)

      described_class.perform_now(command.id)

      expect(conversation.messages.outgoing.where(private: false)).to be_empty
    end
  end

  context 'when a human created the provider command' do
    let(:actor_type) { 'User' }

    it 'does not enqueue or send a customer message' do
      bind_provider_status!('succeeded')
      command.update!(status: 'succeeded')
      described_class.perform_now(command.id)

      expect(described_class).not_to have_received(:perform_later)
      expect(conversation.messages.outgoing.where(private: false)).to be_empty
    end
  end
end
