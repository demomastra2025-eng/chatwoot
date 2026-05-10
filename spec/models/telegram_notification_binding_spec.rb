# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TelegramNotificationBinding do
  let(:user) { create(:user) }
  let(:message) do
    {
      from: {
        id: 12_345,
        username: 'telegram_agent',
        first_name: 'Telegram',
        last_name: 'Agent'
      },
      chat: { id: 67_890 }
    }
  end

  describe '.find_user_by_profile_token' do
    it 'returns a user for an existing profile access token' do
      expect(described_class.find_user_by_profile_token(user.access_token.token)).to eq(user)
    end

    it 'does not return non-user access token owners' do
      agent_bot = create(:agent_bot)

      expect(described_class.find_user_by_profile_token(agent_bot.access_token.token)).to be_nil
    end

    it 'returns nil for unknown tokens' do
      expect(described_class.find_user_by_profile_token('missing-token')).to be_nil
    end
  end

  describe '.verify_user_from_telegram!' do
    it 'creates a binding and marks it connected' do
      binding = described_class.verify_user_from_telegram!(user, message)

      expect(binding).to be_persisted
      expect(binding).to be_connected
      expect(binding.telegram_user_id).to eq('12345')
      expect(binding.telegram_chat_id).to eq('67890')
      expect(binding.username).to eq('telegram_agent')
    end

    it 'reuses the existing binding for the same user' do
      existing_binding = create(:telegram_notification_binding, user: user)

      binding = described_class.verify_user_from_telegram!(user, message)

      expect(binding.id).to eq(existing_binding.id)
      expect(binding).to be_connected
    end

    it 'rejects telegram users already linked to another profile' do
      create(:telegram_notification_binding, :connected, telegram_user_id: '12345')

      expect { described_class.verify_user_from_telegram!(user, message) }
        .to raise_error(ActiveRecord::RecordInvalid)
    end
  end
end
