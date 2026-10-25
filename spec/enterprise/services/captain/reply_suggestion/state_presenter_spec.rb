require 'rails_helper'

RSpec.describe Captain::ReplySuggestion::StatePresenter do
  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account) }
  let(:whatsapp) { create(:inbox, account: account) }
  let(:telegram) { create(:inbox, account: account) }
  let(:asked_in) { create(:conversation, account: account, contact: contact, inbox: whatsapp) }
  let(:other_channel) { create(:conversation, account: account, contact: contact, inbox: telegram) }
  let(:thread) { create(:communication_thread, account: account, contact: contact) }

  # One person, two channels: both conversations are linked to the communication thread of the contact.
  def link_to_thread(*conversations)
    conversations.each do |conversation|
      create(:communication_thread_conversation, communication_thread: thread, conversation: conversation)
      conversation.association(:communication_thread_conversation).reset
      conversation.association(:communication_thread).reset
    end
  end

  def incoming(conversation, content, **attributes)
    create(:message, conversation: conversation, account: account, message_type: :incoming, content: content, **attributes)
  end

  def record(based_on)
    { 'id' => 'req-1', 'account_id' => account.id, 'conversation_id' => asked_in.id, 'based_on_message_id' => based_on&.id }
  end

  describe '.stale?' do
    it 'is true when the person wrote again in another channel of the thread, not only in the conversation it was asked in' do
      link_to_thread(asked_in, other_channel)
      based_on = incoming(asked_in, 'Нужен ЛОР')

      expect(described_class.stale?(record(based_on))).to be(false)

      incoming(other_channel, 'А на завтра можно?')

      expect(described_class.stale?(record(based_on))).to be(true)
    end

    it 'counts only public customer messages of the thread: a private note or an outgoing reply in another channel is not new' do
      link_to_thread(asked_in, other_channel)
      based_on = incoming(asked_in, 'Нужен ЛОР')
      incoming(other_channel, 'Заметка', private: true)
      create(:message, conversation: other_channel, account: account, message_type: :outgoing, content: 'Здравствуйте')

      expect(described_class.stale?(record(based_on))).to be(false)
    end

    it 'does not count a message of another person' do
      link_to_thread(asked_in)
      based_on = incoming(asked_in, 'Нужен ЛОР')
      incoming(create(:conversation, account: account, inbox: telegram), 'Другой человек')

      expect(described_class.stale?(record(based_on))).to be(false)
    end

    it 'reads the conversation alone when it has no thread, and is false without a message or a conversation to compare with' do
      based_on = incoming(asked_in, 'Нужен ЛОР')
      incoming(other_channel, 'Другой канал, без треда')
      expect(described_class.stale?(record(based_on))).to be(false)

      incoming(asked_in, 'А на завтра?')
      expect(described_class.stale?(record(based_on))).to be(true)

      expect(described_class.stale?(record(nil))).to be(false)
      expect(described_class.stale?(record(based_on).merge('conversation_id' => 0))).to be(false)
    end
  end

  describe '#as_json' do
    it 'reports a suggestion as stale after a message in another channel of the person' do
      link_to_thread(asked_in, other_channel)
      based_on = incoming(asked_in, 'Нужен ЛОР')
      incoming(other_channel, 'А на завтра можно?')

      expect(described_class.new(record(based_on).merge('status' => 'draft')).as_json).to include(stale: true)
    end
  end
end
