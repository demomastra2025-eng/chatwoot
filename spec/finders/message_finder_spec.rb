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

      it 'keeps useful activity and hides noisy voice telemetry and Captain tool lines' do
        useful_activity = create(
          :message,
          message_type: 'activity',
          content: 'Conversation assigned to Alex',
          account: account,
          inbox: inbox,
          conversation: conversation
        )
        captain_tool_activity = create(
          :message,
          message_type: 'activity',
          source_id: 'captain-tool:execution-1',
          content_attributes: { data: { type: 'captain_tool_event', event: 'completed', tool_name: 'search_deals' } },
          account: account,
          inbox: inbox,
          conversation: conversation
        )
        noisy_activity = create(
          :message,
          message_type: 'activity',
          source_id: 'ai_voice_event:call:ai_speaking:1',
          account: account,
          inbox: inbox,
          conversation: conversation
        )

        result = message_finder.perform

        expect(result).to include(useful_activity)
        expect(result).not_to include(captain_tool_activity, noisy_activity)
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

    context 'when Captain tool lines are the newest messages' do
      # after the greeting messages that the inbox hooks create with the conversation
      let(:base_time) { 1.day.from_now.change(usec: 0) }
      let(:pagination_conversation) do
        create(:conversation, account: account, inbox: inbox, assignee: user, contact: contact)
      end
      let!(:visible_messages) do
        Array.new(25) do |index|
          create(:message, account: account, inbox: inbox, conversation: pagination_conversation,
                           created_at: base_time + index.minutes)
        end
      end
      let!(:tool_lines) do
        Array.new(30) do |index|
          create(
            :message,
            message_type: 'activity',
            source_id: "captain-tool:page-#{index}",
            content_attributes: { data: { type: 'captain_tool_event', event: 'completed' } },
            account: account,
            inbox: inbox,
            conversation: pagination_conversation,
            created_at: base_time + 100.minutes + index.seconds
          )
        end
      end

      it 'fills the latest page with visible messages instead of hidden lines' do
        result = described_class.new(pagination_conversation, {}).perform

        expect(result.map(&:id)).to eq(visible_messages.last(20).map(&:id))
      end

      it 'loads the next page when the page above was made of hidden lines' do
        first_page = described_class.new(pagination_conversation, {}).perform
        second_page = described_class.new(pagination_conversation, { before: first_page.first.id }).perform

        expect(second_page.map(&:id)).to include(*visible_messages.first(5).map(&:id))
        expect(second_page.last.id).to eq(visible_messages[4].id)
        expect(second_page).not_to include(*tool_lines)
      end

      it 'uses a hidden line as a cursor without returning it' do
        result = described_class.new(pagination_conversation, { before: tool_lines.last.id }).perform

        expect(result.map(&:id)).to eq(visible_messages.last(20).map(&:id))
        expect(result).not_to include(*tool_lines)
      end

      it 'does not return hidden lines for an after cursor' do
        result = described_class.new(pagination_conversation, { after: visible_messages.last.id }).perform

        expect(result).to be_empty
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

      it 'uses the timeline position of a hidden telemetry cursor' do
        hidden_cursor = create(
          :message,
          message_type: 'activity',
          source_id: 'ai_voice_event:call:ai_speaking:cursor',
          account: account,
          inbox: inbox,
          conversation: cursor_conversation,
          created_at: Time.zone.local(2026, 1, 1, 10, 30, 0)
        )

        result = described_class.new(
          cursor_conversation,
          { after: hidden_cursor.id }
        ).perform

        expect(result.first(2).map(&:id)).to eq([middle_message.id, late_message.id])
        expect(result).not_to include(hidden_cursor)
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
