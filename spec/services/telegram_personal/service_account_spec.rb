require 'rails_helper'

RSpec.describe TelegramPersonal::ServiceAccount do
  describe '.chat?' do
    it 'knows the private chats of the Telegram service accounts, whatever the form of the id' do
      expect(described_class.chat?(chat_id: '777000', peer_user_id: '777000', chat_type: 'private')).to be(true)
      expect(described_class.chat?(chat_id: 777_000)).to be(true)
      expect(described_class.chat?('peer_user_id' => '42777', 'chat_type' => 'user')).to be(true)
      expect(described_class.chat?(sender_id: '333000', chat_type: '')).to be(true)
    end

    it 'never takes a person or a group for a service account' do
      expect(described_class.chat?(chat_id: '1777000', peer_user_id: '1777000', chat_type: 'private')).to be(false)
      expect(described_class.chat?(chat_id: '7770001', chat_type: 'private')).to be(false)
      expect(described_class.chat?(chat_id: '-100500', chat_type: 'supergroup', sender_id: '777000')).to be(false)
      expect(described_class.chat?(chat_id: '777000', is_group: true)).to be(false)
      expect(described_class.chat?({})).to be(false)
    end
  end
end
