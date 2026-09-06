require 'rails_helper'

RSpec.describe Reminders::AppointmentProviderGuard do
  let(:conversation) { create(:conversation) }
  let(:account) { conversation.account }
  let!(:contact_inbox) do
    create(:contact_inbox, contact: conversation.contact, inbox: conversation.inbox).tap do |record|
      conversation.update!(contact_inbox: record)
    end
  end
  let(:appointment) { create(:scheduling_appointment, account: account, conversation: conversation) }
  let(:reminder) do
    create(
      :reminder,
      account: account,
      conversation: conversation,
      touch_conversation: conversation,
      remindable: appointment,
      target_conversation: conversation,
      target_contact_inbox: contact_inbox,
      status: :processing,
      scheduled_at: 1.minute.ago,
      processing_started_at: Time.current
    ).tap do |record|
      # rubocop:disable Rails/SkipsModelValidations
      record.update_columns(
        target_conversation_id: conversation.id,
        target_contact_inbox_id: contact_inbox.id
      )
      # rubocop:enable Rails/SkipsModelValidations
    end
  end
  let(:verifier) { instance_double(Integrations::Medelement::AppointmentFreshnessVerifier) }

  before do
    allow(Integrations::Medelement::AppointmentFreshnessVerifier).to receive(:new).and_return(verifier)
  end

  it 'defers a reminder when provider freshness is not proven' do
    checked_at = Time.current
    reminder.update!(metadata: reminder.metadata.to_h.merge(Reminder::PROCESSING_CLAIM_KEY => 'stale-claim'))
    allow(verifier).to receive(:perform).and_return(
      Integrations::Medelement::AppointmentFreshnessVerifier::Result.new(
        status: 'blocked',
        reason: 'provider_unavailable',
        checked_at: checked_at,
        command_id: 12,
        command_status: 'provider_status_unknown'
      )
    )

    expect(described_class.new(reminder: reminder, phase: :materialization).perform).to eq(described_class::STOP)

    expect(reminder.reload.status).to eq('pending')
    expect(reminder.scheduled_at).to be_within(2.seconds).of(5.minutes.from_now)
    expect(reminder.processing_started_at).to be_nil
    expect(reminder.processing_claim_token).to be_nil
    expect(reminder.last_error).to eq('provider_unavailable')
    expect(reminder.metadata.fetch(described_class::METADATA_KEY)).to include(
      'phase' => 'materialization',
      'provider_command_id' => 12,
      'provider_command_status' => 'provider_status_unknown'
    )
  end

  it 'cancels a reminder when the provider reception was removed' do
    reminder.update!(metadata: reminder.metadata.to_h.merge(Reminder::PROCESSING_CLAIM_KEY => 'stale-claim'))
    allow(verifier).to receive(:perform).and_return(
      Integrations::Medelement::AppointmentFreshnessVerifier::Result.new(
        status: 'cancelled',
        reason: 'provider_reception_cancelled',
        checked_at: Time.current,
        command_id: 13,
        command_status: 'succeeded'
      )
    )

    expect(described_class.new(reminder: reminder, phase: :delivery).perform).to eq(described_class::STOP)

    expect(reminder.reload).to be_cancelled
    expect(reminder.cancelled_at).to be_present
    expect(reminder.processing_claim_token).to be_nil
    expect(reminder.last_error).to eq('provider_reception_cancelled')
  end
end
