require 'rails_helper'

RSpec.describe TelegramPersonal::ServiceAccount do
  describe '.chat?' do
    it 'knows the private chat of the Telegram service account, whatever the form of the id' do
      expect(described_class.chat?(chat_id: '777000', peer_user_id: '777000', chat_type: 'private')).to be(true)
      expect(described_class.chat?(chat_id: 777_000)).to be(true)
      expect(described_class.chat?('peer_user_id' => '777000', 'chat_type' => 'user')).to be(true)
      expect(described_class.chat?(sender_id: '777000', chat_type: '')).to be(true)
    end

    it 'never takes a person or a group for a service account' do
      expect(described_class.chat?(chat_id: '1777000', peer_user_id: '1777000', chat_type: 'private')).to be(false)
      expect(described_class.chat?(chat_id: '7770001', chat_type: 'private')).to be(false)
      expect(described_class.chat?(chat_id: '-100500', chat_type: 'supergroup', sender_id: '777000')).to be(false)
      expect(described_class.chat?(chat_id: '777000', is_group: true)).to be(false)
      expect(described_class.chat?({})).to be(false)
    end

    # The importer decides the same way (TelegramPersonal::ChatType): a chat it takes in as private is a chat looked at here
    it 'looks at the chats the importer takes in as private and at nothing else', :aggregate_failures do
      expect(described_class.chat?(chat_type: 'private', is_group: true, peer_user_id: '777000')).to be(true)
      expect(described_class.chat?(chat_type: nil, is_group: true, peer_user_id: '777000')).to be(false)
      expect(described_class.chat?(chat_type: 'channel', peer_user_id: '777000')).to be(false)
    end
  end

  describe '.event?' do
    it 'skips only the events that bring a chat of the service account into the inbox' do
      data = { chat_id: '777000', chat_type: 'private' }

      expect(described_class::CHAT_EVENTS.map { |event| described_class.event?(event, data) }).to all(be(true))
      expect(described_class.event?('message.deleted', data)).to be(false)
      expect(described_class.event?('runtime.updated', data)).to be(false)
      expect(described_class.event?('message.created', data.merge(chat_id: '23'))).to be(false)
    end

    # On the production servers 42777 and 333000 are not reserved: a person with such an id keeps the conversation
    it 'takes 42777 for the service account only on the Telegram test servers', :aggregate_failures do
      expect(described_class.chat?(chat_id: '42777', peer_user_id: '42777', chat_type: 'private')).to be(false)
      expect(described_class.chat?(chat_id: '333000', peer_user_id: '333000', chat_type: 'private')).to be(false)

      with_modified_env(TELEGRAM_PERSONAL_TEST_SERVERS: 'true') do
        expect(described_class.chat?(chat_id: '42777', peer_user_id: '42777', chat_type: 'private')).to be(true)
        expect(described_class.chat?(chat_id: '777000', chat_type: 'private')).to be(true)
      end
    end
  end
end
