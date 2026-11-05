require 'rails_helper'

RSpec.describe TelegramCalls::Config do
  describe '.enabled_for?' do
    it 'defaults to OFF independently of native voice access' do
      account = create(:account)
      account.enable_features!(:channel_voice)

      expect(described_class.enabled_for?(account)).to be(false)
      expect(described_class.enabled_for?(nil)).to be(false)
      expect(described_class.enabled_for?(Account.new)).to be(false)
    end

    it 'permits the bot without native voice and does not reuse stale account or query-cache state' do
      account = create(:account)
      account.disable_features!(:channel_voice)
      account.enable_features!(:telegram_calls_bot)

      Account.cache do
        expect(described_class.enabled_for?(account)).to be(true)
        Account.find(account.id).disable_features!(:telegram_calls_bot)
        expect(account.feature_enabled?('telegram_calls_bot')).to be(true)
        expect(described_class.enabled_for?(account)).to be(false)
      end
    end
  end
end
