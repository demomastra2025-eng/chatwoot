require 'rails_helper'

RSpec.describe AutomationRules::Events::CaptureService do
  before do
    allow(AutomationRules::PublishEventJob).to receive(:perform_later!)
  end

  describe '.capture_model_event!' do
    it 'persists the event in the business transaction and rolls it back with the record' do
      account = create(:account)

      expect do
        Conversation.transaction(requires_new: true) do
          create(:conversation, account: account)
          raise ActiveRecord::Rollback
        end
      end.not_to(change { AutomationEvent.where(account: account).count })
    end

    it 'reuses a stable occurrence identity for callback retries despite snapshot drift' do
      conversation = create(:conversation)
      occurrence_id = SecureRandom.uuid
      events = Conversation.transaction(requires_new: true) do
        first = described_class.capture_model_event!(
          record: conversation,
          event_name: Events::Types::CONVERSATION_UPDATED,
          payload_snapshot: { matcher_data: { status: 'open' } },
          producer: 'conversation_model',
          occurrence_id: occurrence_id
        )
        retry_after_drift = described_class.capture_model_event!(
          record: conversation,
          event_name: Events::Types::CONVERSATION_UPDATED,
          payload_snapshot: { matcher_data: { status: 'resolved' } },
          producer: 'conversation_model',
          occurrence_id: occurrence_id
        )
        [first, retry_after_drift]
      end

      expect(events.map(&:id).uniq.one?).to be(true)
      expect(events.first.dedupe_key).to start_with('model-v2:conversation:')
    end

    it 'keeps identical logical occurrences in separate transactions distinct' do
      conversation = create(:conversation)
      snapshot = { snapshot_version: 1, matcher_kind: 'conversation', matcher_data: { conversation: { status: 'open' } } }

      events = Array.new(2) do
        Conversation.transaction(requires_new: true) do
          described_class.capture_model_event!(
            record: conversation,
            event_name: Events::Types::CONVERSATION_UPDATED,
            payload_snapshot: snapshot,
            changes_snapshot: { status: %w[pending open] },
            producer: 'conversation_model',
            occurrence_id: SecureRandom.uuid
          )
        end
      end

      expect(events.map(&:id).uniq.size).to eq(2)
    end

    it 'does not trust a cross-account Current actor as provenance' do
      conversation = build(:conversation)
      Current.executed_by = create(:user, account: create(:account))

      conversation.save!

      event = AutomationEvent.find_by!(subject_type: 'Conversation', subject_id: conversation.id, event_name: 'conversation_created')
      expect(event.provenance).to include('source' => 'model_callback', 'actor_type' => 'System')
      expect(event.provenance).not_to have_key('actor_id')
    ensure
      Current.reset
    end
  end

  describe '.capture!' do
    it 'rejects cross-account causation before persistence' do
      account = create(:account)
      conversation = create(:conversation, account: account)
      foreign_event = create(:automation_event, account: create(:account))

      expect do
        described_class.capture!(
          account: account,
          event_name: 'conversation_updated',
          subject: conversation,
          payload_snapshot: conversation.webhook_data,
          changes_snapshot: {},
          producer: 'test',
          provenance: { source: 'test' },
          dedupe_key: 'cross-account-causation',
          causation_event: foreign_event
        )
      end.to raise_error(ArgumentError, 'causation event must belong to the account')
    end

    it 'does not hide unrelated validation errors behind a dedupe conflict' do
      conversation = create(:conversation)
      invalid_event = build(:automation_event)
      invalid_event.errors.add(:dedupe_key, :taken)
      invalid_event.errors.add(:producer, :blank)
      error = ActiveRecord::RecordInvalid.new(invalid_event)
      allow(AutomationEvent).to receive(:find_by).and_return(nil)
      allow(AutomationEvent).to receive(:create!).and_raise(error)

      expect do
        described_class.capture!(
          account: conversation.account,
          event_name: 'conversation_updated',
          subject: conversation,
          payload_snapshot: {},
          producer: 'test',
          provenance: { source: 'test' },
          dedupe_key: 'mixed-validation-errors'
        )
      end.to raise_error(error)
    end

    it 'retries an uncached duplicate-winner lookup after a unique race' do
      conversation = create(:conversation)
      winner = create(
        :automation_event,
        account: conversation.account,
        dedupe_key: 'concurrent-winner'
      )
      allow(AutomationEvent).to receive(:find_by).and_return(nil, nil, winner)
      allow(AutomationEvent).to receive(:create!).and_raise(ActiveRecord::RecordNotUnique)
      allow(ApplicationRecord).to receive(:uncached).and_yield

      result = described_class.capture!(
        account: conversation.account,
        event_name: 'conversation_updated',
        subject: conversation,
        payload_snapshot: { matcher: true },
        producer: 'test',
        provenance: { source: 'test' },
        dedupe_key: 'concurrent-winner'
      )

      expect(result).to eq(winner)
      expect(ApplicationRecord).to have_received(:uncached).at_least(:twice)
    end
  end

  it 'captures the supported Message and Appointment event variants without replacing legacy dispatch' do
    message = create(:message)
    appointment = create(:scheduling_appointment)
    starts_at = appointment.starts_at + 1.day

    appointment.update!(starts_at: starts_at, ends_at: starts_at + appointment.duration_min.minutes)

    expect(AutomationEvent.where(subject_type: 'Message', subject_id: message.id).pluck(:event_name)).to include('message_created')
    expect(AutomationEvent.where(subject_type: 'Scheduling::Appointment', subject_id: appointment.id).pluck(:event_name)).to include(
      'appointment_created', 'appointment_updated', 'appointment_rescheduled'
    )
  end

  it 'coalesces multiple Appointment updates into one final envelope per event type and rolls them back together' do
    appointment = create(:scheduling_appointment)
    appointment_events = AutomationEvent.where(subject_type: 'Scheduling::Appointment', subject_id: appointment.id)
    appointment_events.delete_all
    starts_at = appointment.starts_at + 1.day

    Scheduling::Appointment.transaction do
      appointment.update!(starts_at: starts_at, ends_at: starts_at + appointment.duration_min.minutes)
      appointment.update!(status: 'cancelled')
    end

    events = appointment_events
    expect(events.where(event_name: 'appointment_updated').count).to eq(1)
    expect(events.where(event_name: 'appointment_rescheduled').count).to eq(1)
    expect(events.where(event_name: 'appointment_cancelled').count).to eq(1)
    expect(events.find_by!(event_name: 'appointment_updated').changes_snapshot.keys).to include('starts_at', 'ends_at', 'status')

    expect do
      Scheduling::Appointment.transaction(requires_new: true) do
        appointment.update!(status: 'completed')
        raise ActiveRecord::Rollback
      end
    end.not_to(change { appointment_events.count })
  end

  it 'coalesces multiple Conversation updates into final envelopes and drops rolled-back intermediates' do
    conversation = create(:conversation, status: :open)
    conversation_events = AutomationEvent.where(subject_type: 'Conversation', subject_id: conversation.id)
    conversation_events.delete_all

    Conversation.transaction do
      conversation.update!(status: :pending)
      conversation.update!(status: :resolved)
    end

    expect(conversation_events.where(event_name: 'conversation_pending')).to be_empty
    expect(conversation_events.where(event_name: 'conversation_resolved').count).to eq(1)
    updated = conversation_events.find_by!(event_name: 'conversation_updated')
    expect(updated.changes_snapshot.fetch('status')).to eq(%w[open resolved])

    expect do
      Conversation.transaction(requires_new: true) do
        conversation.update!(status: :open)
        raise ActiveRecord::Rollback
      end
    end.not_to(change { conversation_events.count })
  end

  it 'captures complete immutable Conversation and Message matcher inputs before relational drift' do
    conversation = create(:conversation)
    conversation.add_labels(['event-time-label'])
    message = create(:message, conversation: conversation, content: 'event-time-message')
    message_event = AutomationEvent.find_by!(subject_type: 'Message', subject_id: message.id, event_name: 'message_created')
    conversation_event = described_class.capture_model_event!(
      record: conversation,
      event_name: Events::Types::CONVERSATION_UPDATED,
      payload_snapshot: AutomationRules::Events::MatchingSnapshot.for(conversation),
      producer: 'conversation_model',
      changes_snapshot: { status: %w[pending open] },
      occurrence_id: SecureRandom.uuid
    )

    conversation.contact.update!(name: 'later-contact')
    message.update!(content: 'later-message')
    conversation.add_labels(['later-label'])

    [conversation_event, message_event].each do |event|
      matcher_data = event.reload.payload_snapshot.fetch('matcher_data')
      expect(matcher_data.fetch('labels')).to include('event-time-label')
      expect(matcher_data.fetch('messages').map { |snapshot| snapshot['content'] }).to include('event-time-message')
      expect(matcher_data.fetch('contact')['name']).not_to eq('later-contact')
    end
    expect(message_event.payload_snapshot.dig('matcher_data', 'trigger_message', 'content')).to eq('event-time-message')
  end
end
