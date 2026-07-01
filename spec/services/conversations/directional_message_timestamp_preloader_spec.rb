# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Conversations::DirectionalMessageTimestampPreloader do
  subject(:preloader) { described_class.new(account: account) }

  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:base_time) { Time.zone.parse('2026-01-01 12:00:00 UTC') }

  describe '#for_conversations' do
    it 'returns the latest public customer and reply message timestamps per conversation' do
      older_incoming = create(:message, conversation: conversation, account: account, message_type: :incoming, created_at: base_time - 4.hours)
      latest_incoming = create(:message, conversation: conversation, account: account, message_type: :incoming, created_at: base_time - 2.hours)
      latest_outgoing = create(:message, conversation: conversation, account: account, message_type: :outgoing, created_at: base_time - 1.hour)
      create(:message, conversation: conversation, account: account, message_type: :incoming, private: true, created_at: base_time - 30.minutes)
      create(:message, conversation: conversation, account: account, message_type: :activity, created_at: base_time - 10.minutes)

      result = preloader.for_conversations([conversation])

      expect(result[conversation.id]).to eq(
        incoming: latest_incoming.created_at,
        outgoing: latest_outgoing.created_at
      )
      expect(result[conversation.id][:incoming]).not_to eq(older_incoming.created_at)
    end

    it 'treats template messages as replies' do
      template_message = create(:message, conversation: conversation, account: account, message_type: :template, created_at: base_time - 15.minutes)

      result = preloader.for_conversations([conversation])

      expect(result[conversation.id]).to eq(outgoing: template_message.created_at)
    end

    it 'scopes messages to the current account' do
      other_account = create(:account)
      other_conversation = create(:conversation, account: other_account)
      create(:message, conversation: other_conversation, account: other_account, message_type: :incoming, created_at: base_time - 5.minutes)

      expect(preloader.for_conversations([other_conversation])).to eq({})
    end
  end

  describe '#for_communication_threads' do
    it 'aggregates latest directional timestamps across linked conversations' do
      thread = create(:communication_thread, account: account, contact: conversation.contact)
      second_conversation = create(:conversation, account: account, contact: conversation.contact)
      first_link = create(:communication_thread_conversation, communication_thread: thread, conversation: conversation, account: account)
      second_link = create(:communication_thread_conversation, communication_thread: thread, conversation: second_conversation, account: account)
      create(:message, conversation: conversation, account: account, message_type: :incoming, created_at: base_time - 3.hours)
      latest_incoming = create(:message, conversation: second_conversation, account: account, message_type: :incoming, created_at: base_time - 1.hour)
      latest_outgoing = create(:message, conversation: conversation, account: account, message_type: :outgoing, created_at: base_time - 30.minutes)

      result = preloader.for_communication_threads(thread.id => [first_link, second_link])

      expect(result[thread.id]).to eq(
        incoming: latest_incoming.created_at,
        outgoing: latest_outgoing.created_at
      )
    end
  end
end
