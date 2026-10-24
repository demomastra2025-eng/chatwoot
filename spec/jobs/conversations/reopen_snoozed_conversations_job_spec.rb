require 'rails_helper'

RSpec.describe Conversations::ReopenSnoozedConversationsJob do
  it 'enqueues the job' do
    expect { described_class.perform_later }.to have_enqueued_job(described_class)
      .on_queue('low')
  end

  context 'when called' do
    let!(:snoozed_till_5_minutes_ago) { create(:conversation, status: :snoozed, snoozed_until: 5.minutes.ago) }
    let!(:snoozed_till_tomorrow) { create(:conversation, status: :snoozed, snoozed_until: 1.day.from_now) }
    let!(:snoozed_indefinitely) { create(:conversation, status: :snoozed) }

    it 'reopens snoozed conversations whose snooze until has passed' do
      described_class.perform_now

      expect(snoozed_till_5_minutes_ago.reload.status).to eq 'open'
      expect(snoozed_till_tomorrow.reload.status).to eq 'snoozed'
      expect(snoozed_indefinitely.reload.status).to eq 'snoozed'
    end
  end

  # A person (communication thread) wakes in one conversation: one status event per timer, never one per channel.
  context 'with communication threads' do
    let(:account) { create(:account).tap { |record| record.enable_features!('communication_threads') } }
    let(:contact) { create(:contact, account: account) }
    let(:dispatcher) { Rails.configuration.dispatcher }
    let(:status_events) { [] }

    before do
      allow(dispatcher).to receive(:dispatch).and_wrap_original do |original, event, time, data|
        status_events << data[:conversation].id if event == Events::Types::CONVERSATION_STATUS_CHANGED
        original.call(event, time, data)
      end
    end

    def channel(status, minutes_ago:, snoozed_until: nil)
      inbox = create(:inbox, account: account)
      create(:conversation, account: account, contact: contact, inbox: inbox,
                            contact_inbox: create(:contact_inbox, contact: contact, inbox: inbox), status: :resolved).tap do |conversation|
        conversation.update_columns( # rubocop:disable Rails/SkipsModelValidations
          status: Conversation.statuses.fetch(status.to_s), last_activity_at: minutes_ago.minutes.ago, snoozed_until: snoozed_until
        )
      end
    end

    def statuses(*conversations)
      conversations.map { |conversation| conversation.reload.status }
    end

    it 'opens the channel a person is reached in when several share the time, and resolves the others silently', :aggregate_failures do
      older = channel(:snoozed, minutes_ago: 9000, snoozed_until: 1.minute.ago)
      latest = channel(:snoozed, minutes_ago: 10, snoozed_until: 1.minute.ago)
      later_timer = channel(:snoozed, minutes_ago: 500, snoozed_until: 1.day.from_now)

      described_class.perform_now

      expect(statuses(older, latest, later_timer)).to eq(%w[resolved open resolved])
      expect(status_events).to eq([latest.id])
      expect(ConversationStatusTransition.where(conversation_id: [older.id, later_timer.id]).pluck(:to_status, :source).uniq)
        .to eq([%w[resolved system]])
      expect(CommunicationThread.find_by!(account: account, contact: contact).status).to eq('open')
    end

    it 'resolves the snoozed channel silently when the person already has an open dialog', :aggregate_failures do
      sleeping = channel(:snoozed, minutes_ago: 30, snoozed_until: 1.minute.ago)
      open_one = channel(:open, minutes_ago: 300)

      described_class.perform_now

      expect(statuses(sleeping, open_one)).to eq(%w[resolved open])
      expect(status_events).to be_empty
    end

    it 'opens the conversation as before for an account without communication threads' do
      account.disable_features!('communication_threads')
      first = channel(:snoozed, minutes_ago: 30, snoozed_until: 1.minute.ago)
      second = channel(:snoozed, minutes_ago: 60, snoozed_until: 1.minute.ago)

      described_class.perform_now

      expect(statuses(first, second)).to eq(%w[open open])
    end
  end
end
