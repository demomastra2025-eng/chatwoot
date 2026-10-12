require 'rails_helper'

# The AI agent talks only to the calendar and the calendar talks to MedElement. A MedElement outcome, early or late,
# never reaches the conversation: no message, no staff note, no handoff, no status change. The retired job only drains.
RSpec.describe Integrations::Medelement::AiBookingOutcomeJob do
  include ActiveJob::TestHelper

  let(:account) { create(:account, locale: 'ru').tap { |record| record.enable_features!('scheduling') } }
  let(:assistant) { create(:captain_assistant, account: account, usage_mode: 'external_agent') }
  let(:contact) { create(:contact, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, status: :pending) }
  let(:resource) { create(:scheduling_resource, account: account, custom_attributes: { 'medelement_specialist_code' => 'specialist-1' }) }
  let(:appointment) { create(:scheduling_appointment, account: account, contact: contact, conversation: conversation, resource: resource) }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }
  let(:operation) { 'create_reception' }
  let(:command) do
    Integrations::Medelement::ProviderCommand.create!(
      account: account, hook: hook, appointment: appointment, contact: contact,
      operation: operation, status: 'queued',
      desired_starts_at: appointment.starts_at, desired_ends_at: appointment.ends_at,
      company_cabinet_code: 'cab-1', idempotency_key: 'ai-booking-1', provider_reception_code: 'reception-1',
      execution_state: {
        'request_fingerprint' => 'booking-fingerprint', 'dispatch_identity' => 'booking-dispatch-1',
        'request_snapshot' => {
          'version' => 2, 'actor' => { 'type' => 'Captain::Assistant', 'id' => assistant.id },
          'account_id' => account.id, 'appointment_id' => appointment.id, 'contact_id' => contact.id,
          'conversation_id' => conversation.id,
          'reception' => {
            'resource_id' => resource.id, 'destination_starts_at' => appointment.starts_at.utc.iso8601(6),
            'destination_ends_at' => appointment.ends_at.utc.iso8601(6), 'nomenclature_codes' => []
          }
        }
      }
    )
  end

  before do
    create(:captain_inbox, inbox: inbox, captain_assistant: assistant)
    command
    clear_enqueued_jobs
  end

  def expect_conversation_untouched
    expect(conversation.messages.outgoing).to be_empty
    expect(conversation.reload.status).to eq('pending')
    expect(conversation.current_captain_control_state).not_to eq('human')
  end

  %w[succeeded failed provider_status_unknown reconciliation_required declined cancelled].each do |outcome|
    it "does not enqueue an outcome job or touch the conversation when an AI create ends #{outcome}" do
      command.update!(status: outcome, provider_patient_code: 'patient-1',
                      execution_state: command.execution_state.merge('write_provider_reception_code' => 'reception-1'))

      expect(described_class).not_to have_been_enqueued
      expect_conversation_untouched
    end
  end

  it 'does not enqueue an outcome job or touch the conversation when an AI move ends in failure' do
    command.update!(status: 'succeeded')
    clear_enqueued_jobs
    move = Integrations::Medelement::ProviderCommand.create!(
      account: account, hook: hook, appointment: appointment, contact: contact, operation: 'move_reception', status: 'queued',
      desired_starts_at: appointment.starts_at + 1.day, desired_ends_at: appointment.ends_at + 1.day, company_cabinet_code: 'cab-1',
      idempotency_key: 'ai-move-1', provider_reception_code: 'reception-1',
      execution_state: { 'request_snapshot' => { 'actor' => { 'type' => 'Captain::Assistant', 'id' => assistant.id } } }
    )

    move.update!(status: 'failed', last_error_code: 'slot_conflict')

    expect(described_class).not_to have_been_enqueued
    expect_conversation_untouched
  end

  it 'does nothing for a job that was enqueued before the change' do
    command.update!(status: 'failed')

    expect { described_class.perform_now(command.id) }.not_to(change { conversation.messages.count })

    expect_conversation_untouched
    expect(command.reload.execution_state.keys).not_to include('ai_booking_customer_message_id', 'ai_booking_staff_note_id')
  end
end
