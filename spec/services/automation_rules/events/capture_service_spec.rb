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

    it 'deduplicates repeated callbacks with an account-scoped deterministic key' do
      conversation = create(:conversation)
      event = AutomationEvent.find_by!(subject_type: 'Conversation', subject_id: conversation.id, event_name: 'conversation_created')

      duplicate = described_class.capture_model_event!(
        record: conversation,
        event_name: Events::Types::CONVERSATION_CREATED,
        payload_snapshot: event.payload_snapshot,
        producer: 'conversation_model'
      )

      expect(duplicate).to eq(event)
      expect(AutomationEvent.where(account: conversation.account, dedupe_key: event.dedupe_key).count).to eq(1)
    end

    it 'distinguishes logical updates at the same timestamp while deduplicating each callback retry' do
      conversation = create(:conversation)
      fixed_timestamp = conversation.updated_at
      snapshots = [
        { snapshot_version: 1, matcher_kind: 'conversation', matcher_data: { conversation: { status: 'open' } } },
        { snapshot_version: 1, matcher_kind: 'conversation', matcher_data: { conversation: { status: 'resolved' } } }
      ]

      events = snapshots.flat_map do |snapshot|
        conversation.updated_at = fixed_timestamp
        Array.new(2) do
          described_class.capture_model_event!(
            record: conversation,
            event_name: Events::Types::CONVERSATION_UPDATED,
            payload_snapshot: snapshot,
            changes_snapshot: { status: %w[open resolved] },
            producer: 'conversation_model'
          )
        end
      end

      expect(events.map(&:id).uniq.size).to eq(2)
      expect(events.each_slice(2).map { |pair| pair.map(&:id).uniq.size }).to eq([1, 1])
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
      changes_snapshot: { status: %w[pending open] }
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
