require 'rails_helper'

describe MessageFinder do
  subject(:message_finder) { described_class.new(conversation, params) }

  let!(:account) { create(:account) }
  let!(:user) { create(:user, account: account) }
  let!(:inbox) { create(:inbox, account: account) }
  let!(:contact) { create(:contact, account: account, email: nil) }
  let!(:conversation) do
    create(:conversation, account: account, inbox: inbox, assignee: user, contact: contact)
  end

  before do
    create(:message, account: account, inbox: inbox, conversation: conversation)
    create(:message, message_type: 'activity', account: account, inbox: inbox, conversation: conversation)
    create(:message, message_type: 'activity', account: account, inbox: inbox, conversation: conversation)
    # this outgoing message creates 2 additional messages because of the email hook execution service
    create(:message, message_type: 'outgoing', account: account, inbox: inbox, conversation: conversation)
  end

  describe '#perform' do
    context 'with filter_internal_messages false' do
      let(:params) { { filter_internal_messages: false } }

      it 'filter conversations by status' do
        result = message_finder.perform
        expect(result.count).to be 6
      end
    end

    context 'with filter_internal_messages true' do
      let(:params) { { filter_internal_messages: true } }

      it 'filter conversations by status' do
        result = message_finder.perform
        expect(result.count).to be 4
      end
    end

    context 'with before attribute' do
      let!(:outgoing) { create(:message, message_type: 'outgoing', account: account, inbox: inbox, conversation: conversation) }
      let(:params) { { before: outgoing.id } }

      it 'filter conversations by status' do
        result = message_finder.perform
        expect(result.count).to be 6
      end
    end

    context 'with after attribute' do
      let(:params) { { after: conversation.messages.first.id } }

      it 'filter conversations by status' do
        result = message_finder.perform
        expect(result.count).to be 5
        expect(result.first.id).to be conversation.messages.second.id
        expect(result.last.message_type).to eq 'outgoing'
      end
    end

    context 'with after and before attribute' do
      let(:params) do
        {
          after: conversation.messages.first.id,
          before: conversation.messages.last.id
        }
      end

      it 'filter conversations by status' do
        result = message_finder.perform
        expect(result.count).to be 5
        expect(result.last.id).to be conversation.messages[-2].id
      end
    end

    context 'when message ids do not match timeline order' do
      let!(:early_message) do
        create(
          :message,
          account: account,
          inbox: inbox,
          conversation: cursor_conversation,
          created_at: Time.zone.local(2026, 1, 1, 10, 0, 0)
        )
      end
      let!(:late_message) do
        create(
          :message,
          account: account,
          inbox: inbox,
          conversation: cursor_conversation,
          created_at: Time.zone.local(2026, 1, 1, 12, 0, 0)
        )
      end
      let!(:middle_message) do
        create(
          :message,
          account: account,
          inbox: inbox,
          conversation: cursor_conversation,
          created_at: Time.zone.local(2026, 1, 1, 11, 0, 0)
        )
      end
      let(:cursor_conversation) do
        create(
          :conversation,
          account: account,
          inbox: inbox,
          assignee: user,
          contact: contact
        )
      end

      it 'loads messages after the cursor by created_at and id instead of id alone' do
        result = described_class.new(
          cursor_conversation,
          { after: early_message.id }
        ).perform

        expect(result.select(&:incoming?).map(&:id)).to eq(
          [middle_message.id, late_message.id]
        )
      end

      it 'loads messages before the cursor by created_at and id instead of id alone' do
        result = described_class.new(
          cursor_conversation,
          { before: late_message.id }
        ).perform

        expect(result.map(&:id)).to eq([early_message.id, middle_message.id])
      end

      it 'loads the inclusive after/exclusive before window around the first unread cursor' do
        result = described_class.new(
          cursor_conversation,
          { after: middle_message.id, before: late_message.id }
        ).perform

        expect(result.map(&:id)).to eq([middle_message.id])
      end
    end
  end
end
