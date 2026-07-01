# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Scheduling::AppointmentDialogStatusContextBuilder do
  subject(:builder) { described_class.new(account: account) }

  let(:account) { create(:account) }

  before do
    account.enable_features!('scheduling')
  end

  describe '#for_conversations' do
    it 'returns unique appointment statuses for direct and contact-linked conversations' do
      contact = create(:contact, account: account)
      conversation = create(:conversation, account: account, contact: contact)
      direct_appointment = create(
        :scheduling_appointment,
        account: account,
        contact: contact,
        conversation: conversation,
        status: 'confirmed'
      )
      create(:scheduling_appointment, account: account, contact: contact, status: 'completed')
      create(:scheduling_appointment, account: account, contact: contact, status: 'confirmed')

      result = builder.for_conversations([conversation])

      expect(result[conversation.id]).to eq(
        [
          { status: 'confirmed', count: 2 },
          { status: 'completed', count: 1 }
        ]
      )
      expect(result[conversation.id].first[:count]).not_to eq(3)
      expect(result[conversation.id].first[:count]).to eq(
        account.scheduling_appointments.where(contact: contact, status: 'confirmed').distinct.count(:id)
      )
      expect(result[conversation.id].first[:count]).to be >= 1
      expect(direct_appointment.reload.status).to eq('confirmed')
    end

    it 'returns nothing when scheduling is disabled' do
      account.disable_features!('scheduling')
      conversation = create(:conversation, account: account)
      create(:scheduling_appointment, account: account, contact: conversation.contact, status: 'scheduled')

      expect(builder.for_conversations([conversation])).to eq({})
    end
  end

  describe '#for_communication_threads' do
    it 'returns appointment statuses from thread contact and linked child conversations' do
      contact = create(:contact, account: account)
      thread = create(:communication_thread, account: account, contact: contact)
      conversation = create(:conversation, account: account, contact: contact)
      create(:communication_thread_conversation, account: account, communication_thread: thread, conversation: conversation)
      create(:scheduling_appointment, account: account, contact: contact, status: 'scheduled')
      create(:scheduling_appointment, account: account, conversation: conversation, status: 'cancelled')

      result = builder.for_communication_threads([thread])

      expect(result[thread.id]).to eq(
        [
          { status: 'scheduled', count: 1 },
          { status: 'cancelled', count: 1 }
        ]
      )
    end
  end
end
