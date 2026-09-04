# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Scheduling::AppointmentDialogCountService do
  describe '#communication_thread_status_counts' do
    let(:account) { create(:account) }

    it 'returns exact status and distinct any counts with one aggregate query' do
      first_contact = create(:contact, account: account)
      first_thread = create(:communication_thread, account: account, contact: first_contact)
      first_conversation = create(:conversation, account: account, contact: first_contact)
      create(
        :communication_thread_conversation,
        account: account,
        communication_thread: first_thread,
        conversation: first_conversation
      )

      second_contact = create(:contact, account: account)
      second_thread = create(:communication_thread, account: account, contact: second_contact)
      second_conversation = create(:conversation, account: account, contact: second_contact)
      create(
        :communication_thread_conversation,
        account: account,
        communication_thread: second_thread,
        conversation: second_conversation
      )

      create(:scheduling_appointment, account: account, contact: first_contact, status: 'confirmed')
      create(:scheduling_appointment, account: account, contact: first_contact, status: 'completed')
      create(
        :scheduling_appointment,
        account: account,
        contact: second_contact,
        conversation: second_conversation,
        status: 'scheduled'
      )

      aggregate_queries = []
      callback = lambda do |_name, _started, _finished, _id, payload|
        sql = payload[:sql].to_s
        aggregate_queries << sql if sql.include?('appointment_dialog_rows')
      end
      service = described_class.new(
        account: account,
        communication_thread_scope: CommunicationThread.where(id: [first_thread.id, second_thread.id])
      )

      result = ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
        service.communication_thread_status_counts
      end

      expect(result).to eq(
        'confirmed' => 1,
        'completed' => 1,
        'scheduled' => 1,
        'any' => 2
      )
      expect(aggregate_queries.one?).to be(true)
      expect(aggregate_queries.first).to include('GROUP BY GROUPING SETS')
    end

    it 'returns an empty count set when no appointments match' do
      expect(
        described_class.new(
          account: account,
          communication_thread_scope: CommunicationThread.none
        ).communication_thread_status_counts
      ).to eq({})
    end
  end
end
