require 'rails_helper'

# A failed Captain booking must leave a staff note for the human who took the
# conversation over after the booking fence (product rule 3.1), whichever way
# the takeover happened, without reading the legacy captain_control_state column.
RSpec.describe Integrations::Medelement::AiBookingOutcomeJob do
  let(:account) { create(:account, locale: 'ru').tap { |record| record.enable_features!('scheduling') } }
  let(:assistant) { create(:captain_assistant, account: account, usage_mode: 'external_agent') }
  let(:contact) { create(:contact, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, status: :pending) }
  let(:resource) { create(:scheduling_resource, account: account, custom_attributes: { 'medelement_specialist_code' => 'specialist-1' }) }
  let(:appointment) { create(:scheduling_appointment, account: account, contact: contact, conversation: conversation, resource: resource) }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:command) do
    Integrations::Medelement::ProviderCommand.create!(
      account: account, hook: hook, appointment: appointment, contact: contact,
      operation: 'create_reception', status: 'queued',
      desired_starts_at: appointment.starts_at, desired_ends_at: appointment.ends_at,
      company_cabinet_code: 'cab-1', idempotency_key: 'ai-booking-takeover-1',
      provider_reception_code: 'reception-1',
      execution_state: {
        'request_fingerprint' => 'booking-fingerprint', 'dispatch_identity' => 'booking-dispatch-1',
        'request_snapshot' => {
          'version' => 2,
          'actor' => { 'type' => 'Captain::Assistant', 'id' => assistant.id },
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
    create(:inbox_member, user: agent, inbox: inbox)
  end

  def bind_failed_provider_status!
    status = Integrations::Medelement::AppointmentProviderStatus
    appointment.update!(custom_attributes: appointment.custom_attributes.to_h.merge(
      'medelement_cabinet_code' => 'cab-1',
      status::ATTRIBUTE_KEY => 'failed',
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

  def staff_notes
    conversation.messages.outgoing.where(private: true)
  end

  it 'leaves a staff note when an agent public reply took over before the booking failed' do
    bind_failed_provider_status!
    capture_booking_fence!
    create(:message, conversation: conversation, account: account, inbox: inbox, message_type: :outgoing,
                     sender: agent, private: false, content: 'agent reply')
    command.update!(status: 'failed')

    described_class.perform_now(command.id)

    expect(conversation.reload.status).to eq('open')
    expect(staff_notes.count).to eq(1)
    expect(command.reload.execution_state['ai_booking_staff_note_id']).to eq(staff_notes.first.id)
  end

  it 'leaves a staff note when an agent was already assigned to the pending conversation' do
    bind_failed_provider_status!
    capture_booking_fence!
    conversation.update!(assignee: agent)
    command.update!(status: 'failed')

    described_class.perform_now(command.id)

    expect(conversation.reload.status).to eq('open')
    expect(staff_notes.count).to eq(1)
    expect(command.reload.execution_state['ai_booking_staff_note_id']).to eq(staff_notes.first.id)
  end

  it 'leaves a staff note when a handoff opened the conversation before the booking failed' do
    bind_failed_provider_status!
    capture_booking_fence!
    expect(conversation.bot_handoff!(actor: agent)).to eq(:applied)
    command.update!(status: 'failed')

    described_class.perform_now(command.id)

    expect(conversation.reload.status).to eq('open')
    expect(staff_notes.count).to eq(1)
    expect(command.reload.execution_state['ai_booking_staff_note_id']).to eq(staff_notes.first.id)
  end

  context 'when a staff member replied in a non-Captain channel of the same communication thread' do
    let(:sibling) { create(:conversation, account: account, contact: contact, status: :open) }
    let(:thread) { create(:communication_thread, account: account, contact: contact) }

    before do
      [conversation, sibling].each do |candidate|
        create(:communication_thread_conversation, communication_thread: thread, conversation: candidate)
        candidate.association(:communication_thread_conversation).reset
        candidate.association(:communication_thread).reset
      end
      allow(Captain::Conversation::TypingIndicatorService).to receive(:turn_off)
    end

    after { Redis::Alfred.delete(format(Redis::Alfred::CAPTAIN_RESPONSE_CANCELLATION_STATE, conversation_id: conversation.id)) }

    it 'leaves a staff note while the Captain conversation stays pending' do
      bind_failed_provider_status!
      capture_booking_fence!
      create(:message, conversation: sibling, account: account, inbox: sibling.inbox, message_type: :outgoing,
                       sender: agent, private: false, content: 'agent reply')
      command.update!(status: 'failed')

      described_class.perform_now(command.id)

      expect(conversation.reload).to be_pending
      expect(staff_notes.count).to eq(1)
      expect(conversation.messages.outgoing.where(private: false)).to be_empty
      expect(command.reload.execution_state['ai_booking_staff_note_id']).to eq(staff_notes.first.id)
    end
  end
end
