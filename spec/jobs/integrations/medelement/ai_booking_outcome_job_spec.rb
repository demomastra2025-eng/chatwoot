require 'rails_helper'

RSpec.describe Integrations::Medelement::AiBookingOutcomeJob do
  let(:account) { create(:account, locale: 'ru').tap { |record| record.enable_features!('scheduling') } }
  let(:assistant) { create(:captain_assistant, account: account, usage_mode: 'external_agent') }
  let(:contact) { create(:contact, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, status: :pending) }
  let(:appointment) do
    create(:scheduling_appointment, account: account, contact: contact, conversation: conversation)
  end
  let(:hook) { create(:integrations_hook, :medelement, account: account) }
  let(:actor_type) { 'Captain::Assistant' }
  let(:initial_reception_code) { 'reception-1' }
  let(:operation) { 'create_reception' }
  let(:command) do
    Integrations::Medelement::ProviderCommand.create!(
      account: account,
      hook: hook,
      appointment: appointment,
      contact: contact,
      operation: operation,
      status: 'queued',
      desired_starts_at: appointment.starts_at,
      desired_ends_at: appointment.ends_at,
      company_cabinet_code: 'cab-1',
      idempotency_key: 'ai-booking-1',
      provider_reception_code: initial_reception_code,
      execution_state: {
        'request_fingerprint' => 'booking-fingerprint',
        'dispatch_identity' => 'booking-dispatch-1',
        'request_snapshot' => {
          'actor' => { 'type' => actor_type, 'id' => assistant.id },
          'account_id' => account.id,
          'appointment_id' => appointment.id,
          'contact_id' => contact.id,
          'conversation_id' => conversation.id,
          'reception' => { 'destination_starts_at' => appointment.starts_at.utc.iso8601(6) }
        }
      }
    )
  end

  before { allow(described_class).to receive(:perform_later) }

  def bind_provider_status!(status)
    provider_status = Integrations::Medelement::AppointmentProviderStatus
    appointment.update!(custom_attributes: appointment.custom_attributes.to_h.merge(
      provider_status::ATTRIBUTE_KEY => status,
      provider_status::COMMAND_ID_KEY => command.id,
      provider_status::COMMAND_IDEMPOTENCY_KEY => command.idempotency_key,
      provider_status::COMMAND_FINGERPRINT_KEY => 'booking-fingerprint',
      provider_status::COMMAND_DISPATCH_IDENTITY_KEY => 'booking-dispatch-1'
    ))
  end

  it 'sends exactly one confirmation when the provider returned a reception ID' do
    bind_provider_status!('succeeded')
    command.update!(execution_state: command.execution_state.merge('write_provider_reception_code' => 'reception-1'))
    expect(described_class).to receive(:perform_later).with(command.id).once
    command.update!(status: 'succeeded')

    expect { described_class.perform_now(command.id) }
      .to change { conversation.messages.outgoing.where(private: false).count }.by(1)
    described_class.perform_now(command.id)

    message = conversation.messages.outgoing.where(private: false).last
    expect(message.content).to include('Ваша запись подтверждена')
    expect(command.reload.execution_state[described_class::CUSTOMER_MESSAGE_ID_KEY]).to eq(message.id)
    expect(conversation.messages.outgoing.where(private: false).count).to eq(1)
  end

  it 'does not send a late customer confirmation when no reception ID came from the write response' do
    bind_provider_status!('succeeded')
    command.update!(status: 'succeeded')

    described_class.perform_now(command.id)
    described_class.perform_now(command.id)

    expect(conversation.messages.outgoing.where(private: false)).to be_empty
    expect(conversation.messages.outgoing.where(private: true).count).to eq(1)
    expect(conversation.reload.status).to eq('pending')
  end

  context 'when MedElement confirms a reschedule' do
    let(:operation) { 'move_reception' }

    it 'replies after read-back, not simply because the existing reception already had an ID' do
      bind_provider_status!('pending')
      command.update!(status: 'processing')
      described_class.perform_now(command.id)
      expect(conversation.messages.outgoing.where(private: false)).to be_empty

      bind_provider_status!('succeeded')
      command.update!(status: 'succeeded')
      described_class.perform_now(command.id)

      expect(conversation.messages.outgoing.where(private: false).last.content).to include('Ваша запись перенесена')
    end
  end

  context 'when MedElement has not yet returned a reception ID' do
    let(:initial_reception_code) { nil }

    it 'queues an outcome when the executor persists the returned ID, before read-back' do
      bind_provider_status!('pending')
      executor = Integrations::Medelement::ProviderCommands::Executor.new(command: command)
      command.update!(
        status: 'processing',
        execution_state: command.execution_state.merge('claim_token' => executor.send(:claim_token))
      )

      expect(described_class).to receive(:perform_later).with(command.id).once
      executor.send(:record_write_reference!, provider_reception_code: 'reception-1')

      expect(command.reload.provider_reception_code).to eq('reception-1')
      expect(command.status).to eq('processing')
    end

    it 'does not tell the customer a local calendar booking is provider-confirmed' do
      bind_provider_status!('pending')
      command.update!(status: 'processing')

      described_class.perform_now(command.id)

      expect(conversation.messages.outgoing.where(private: false)).to be_empty
    end

    it 'confirms once when a valid ID arrives, before provider read-back materializes' do
      bind_provider_status!('pending')
      command.update!(
        status: 'processing',
        provider_reception_code: 'reception-1',
        execution_state: command.execution_state.merge('write_provider_reception_code' => 'reception-1')
      )

      described_class.perform_now(command.id)
      expect(conversation.messages.outgoing.where(private: false).count).to eq(1)
      expect(appointment.reload.custom_attributes['medelement_provider_sync_status']).to eq('pending')

      bind_provider_status!('succeeded')
      command.update!(status: 'succeeded')
      described_class.perform_now(command.id)
      expect(conversation.messages.outgoing.where(private: false).count).to eq(1)
    end

    it 'alerts staff if read-back remains unknown after the ID was sent to the customer' do
      bind_provider_status!('pending')
      command.update!(
        status: 'processing', provider_reception_code: 'reception-1',
        execution_state: command.execution_state.merge('write_provider_reception_code' => 'reception-1')
      )
      described_class.perform_now(command.id)
      command.update!(status: 'provider_status_unknown')

      described_class.perform_now(command.id)

      expect(conversation.messages.outgoing.where(private: false).count).to eq(1)
      expect(conversation.messages.outgoing.where(private: true).last.content).to include('Клиент уже получил подтверждение')
    end
  end

  it 'does not promise a booking when a later attempt superseded the command' do
    bind_provider_status!('succeeded')
    command.update!(status: 'succeeded')
    Integrations::Medelement::AppointmentProviderStatus.assign_pending!(appointment)
    appointment.save!

    described_class.perform_now(command.id)

    expect(conversation.messages.outgoing.where(private: false)).to be_empty
    expect(conversation.reload.status).to eq('pending')
    expect(conversation.messages.outgoing.where(private: true).count).to eq(1)
  end

  it 'rechecks the appointment binding if a later attempt supersedes the loaded record' do
    bind_provider_status!('succeeded')
    command.update!(status: 'succeeded', execution_state: command.execution_state.merge('write_provider_reception_code' => 'reception-1'))
    job = described_class.new
    allow(job).to receive(:deliver_confirmation!).and_wrap_original do |method, *args|
      appointment.reload
      Integrations::Medelement::AppointmentProviderStatus.assign_pending!(appointment)
      appointment.save!
      method.call(*args)
    end

    job.perform(command.id)

    expect(conversation.messages.outgoing.where(private: false)).to be_empty
    expect(conversation.messages.outgoing.where(private: true).count).to eq(1)
  end

  it 'does not confirm in the old conversation when an appointment is rebound while the job waits' do
    other_conversation = create(:conversation, account: account, inbox: inbox, contact: contact, status: :pending)
    bind_provider_status!('succeeded')
    command.update!(status: 'succeeded', execution_state: command.execution_state.merge('write_provider_reception_code' => 'reception-1'))
    job = described_class.new
    allow(job).to receive(:deliver_confirmation!).and_wrap_original do |method, *args|
      appointment.reload.update!(conversation: other_conversation)
      method.call(*args)
    end

    job.perform(command.id)

    expect(conversation.messages.outgoing.where(private: false)).to be_empty
    expect(other_conversation.messages.outgoing.where(private: false)).to be_empty
    expect(command.reload.execution_state[described_class::STAFF_NOTE_ID_KEY]).to be_present
  end

  it 'does not confirm in a new conversation when the appointment was rebound before the job loaded it' do
    other_conversation = create(:conversation, account: account, inbox: inbox, contact: contact, status: :pending)
    bind_provider_status!('succeeded')
    command.update!(status: 'succeeded', execution_state: command.execution_state.merge('write_provider_reception_code' => 'reception-1'))
    appointment.update!(conversation: other_conversation)

    described_class.perform_now(command.id)

    expect(conversation.messages.outgoing.where(private: false)).to be_empty
    expect(other_conversation.messages.outgoing.where(private: false)).to be_empty
    expect(conversation.messages.outgoing.where(private: true).count).to eq(1)
    expect(other_conversation.messages.outgoing.where(private: true)).to be_empty
  end

  it 'does not confirm a legacy command without an original conversation identity' do
    bind_provider_status!('succeeded')
    snapshot = command.execution_state.to_h.fetch('request_snapshot').except('conversation_id')
    command.update!(status: 'succeeded', execution_state: command.execution_state.merge(
      'request_snapshot' => snapshot, 'write_provider_reception_code' => 'reception-1'
    ))

    described_class.perform_now(command.id)

    expect(conversation.messages.outgoing.where(private: false)).to be_empty
    expect(conversation.messages.outgoing.where(private: true).count).to eq(1)
  end

  it 'does not send a late booking confirmation after a human takes over' do
    bind_provider_status!('succeeded')
    command.update!(status: 'succeeded')
    conversation.update!(status: :open)

    described_class.perform_now(command.id)

    expect(conversation.reload.status).to eq('open')
    expect(conversation.messages.outgoing.where(private: false)).to be_empty
    expect(conversation.messages.outgoing.where(private: true).count).to eq(1)
  end

  it 'does not confirm after a human reply commits before its status callback opens the conversation' do
    create(:captain_inbox, captain_assistant: assistant, inbox: inbox)
    bind_provider_status!('succeeded')
    command.update!(status: 'succeeded', execution_state: command.execution_state.merge('write_provider_reception_code' => 'reception-1'))
    human_message = build(:message, conversation: conversation, account: account, inbox: inbox,
                                    sender: create(:user, account: account), message_type: :outgoing)
    allow(human_message).to receive(:execute_after_create_commit_callbacks)
    human_message.save!
    expect(conversation.reload.status).to eq('pending')

    described_class.perform_now(command.id)

    expect(conversation.messages.outgoing.where(sender: assistant, private: false)).to be_empty
    expect(conversation.messages.outgoing.where(sender: assistant, private: true).count).to eq(1)
  end

  it 'leaves a failed booking pending and records one private note without a customer message' do
    bind_provider_status!('failed')
    command.update!(status: 'failed')

    described_class.perform_now(command.id)
    described_class.perform_now(command.id)

    expect(conversation.reload.status).to eq('pending')
    expect(conversation.messages.outgoing.where(private: false)).to be_empty
    expect(conversation.messages.outgoing.where(private: true).count).to eq(1)
    expect(command.reload.execution_state[described_class::STAFF_NOTE_ID_KEY]).to be_present
  end

  it 'never forces handoff from the provider outcome notification' do
    expect(conversation).not_to receive(:bot_handoff!)

    described_class.new.send(:notify_staff!, command, conversation, assistant)

    expect(conversation.messages.outgoing.where(private: true).count).to eq(1)
  end

  it 'keeps an unknown provider outcome with staff, even if reconciliation later succeeds' do
    bind_provider_status!('provider_status_unknown')
    command.update!(status: 'provider_status_unknown')
    described_class.perform_now(command.id)

    command.update!(status: 'succeeded')
    described_class.perform_now(command.id)

    expect(conversation.messages.outgoing.where(private: false)).to be_empty
    expect(conversation.messages.outgoing.where(private: true).count).to eq(1)
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
