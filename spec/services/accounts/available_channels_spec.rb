# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Accounts::AvailableChannels do
  let(:channel_flags) { %w[channel_website channel_facebook channel_instagram channel_tiktok channel_email channel_voice channel_twitter] }
  let(:account) { create(:account).tap { |record| record.enable_features!(*channel_flags) } }
  let(:default_channels) do
    %w[website facebook instagram whatsapp_cloud whatsapp_twilio whatsapp_web telegram_bot telegram_personal email voice]
  end

  it 'offers the channels that are shown by default, in catalog order' do
    expect(described_class.for(account)).to eq(default_channels)
  end

  it 'never offers the channels the platform hides by default' do
    expect(described_class.for(account)).not_to include('twitter', 'weixin', 'line', 'vk_community', 'tiktok', 'sms', 'api')
  end

  context 'with a platform switch' do
    it 'drops a channel the platform hides' do
      change_platform_channel_visibility('facebook' => 'hidden', 'whatsapp_web' => 'hidden')

      expect(described_class.for(account)).to eq(default_channels - %w[facebook whatsapp_web])
    end

    it 'adds a channel the platform shows' do
      change_platform_channel_visibility('api' => 'shown', 'sms' => 'shown')

      expect(described_class.for(account)).to eq(default_channels + %w[sms api])
    end
  end

  context 'with an exception on the clinic' do
    it 'shows a hidden channel to one clinic only' do
      other_account = create(:account).tap { |record| record.enable_features!(*channel_flags) }
      show_channels_for(account, 'api')

      expect(described_class.available?(account, 'api')).to be(true)
      expect(described_class.available?(other_account, 'api')).to be(false)
    end

    it 'hides a shown channel from one clinic only' do
      other_account = create(:account).tap { |record| record.enable_features!(*channel_flags) }
      hide_channels_for(account, 'telegram_personal')

      expect(described_class.for(account)).not_to include('telegram_personal')
      expect(described_class.for(other_account)).to include('telegram_personal')
    end

    it 'wins over a platform switch in both directions' do
      change_platform_channel_visibility('api' => 'shown', 'website' => 'hidden')
      hide_channels_for(account, 'api')
      show_channels_for(account, 'website')

      expect(described_class.available?(account, 'api')).to be(false)
      expect(described_class.available?(account, 'website')).to be(true)
    end

    it 'follows the platform again once the exception is removed' do
      show_channels_for(account, 'api')
      Accounts::ChannelOverrides.new(account: account).apply('api' => 'default')

      expect(described_class.available?(account.reload, 'api')).to be(false)
    end
  end

  context 'when the clinic does not have the feature flag of the channel' do
    it 'does not offer a shown channel' do
      account.disable_features!('channel_website', 'channel_voice')

      expect(described_class.available?(account, 'website')).to be(false)
      expect(described_class.available?(account, 'voice')).to be(false)
      expect(described_class.for(account)).to include('facebook', 'email')
    end

    it 'does not offer it even when an exception shows it' do
      account.disable_features!('channel_tiktok')
      show_channels_for(account, 'tiktok')

      expect(described_class.available?(account.reload, 'tiktok')).to be(false)
    end

    it 'offers it once the flag is on and the channel is shown' do
      account.disable_features!('channel_tiktok')
      show_channels_for(account, 'tiktok')
      account.enable_features!('channel_tiktok')

      expect(described_class.available?(account.reload, 'tiktok')).to be(true)
    end

    it 'does not look for a flag on a channel that has none' do
      account.disable_features!(*channel_flags)

      expect(described_class.for(account)).to eq(%w[whatsapp_cloud whatsapp_twilio whatsapp_web telegram_bot telegram_personal])
    end
  end

  describe '.overrides' do
    it 'ignores entries of unknown channels and unusable states' do
      account.update!(custom_attributes: { described_class::OVERRIDES_KEY => { 'api' => 'shown', 'ghost' => 'shown', 'sms' => 'maybe' } })

      expect(described_class.overrides(account)).to eq('api' => 'shown')
    end

    it 'is empty for an account without them or with a broken value' do
      expect(described_class.overrides(account)).to eq({})

      account.update!(custom_attributes: { described_class::OVERRIDES_KEY => 'shown' })
      expect(described_class.overrides(account)).to eq({})
    end
  end

  describe '.available? and .ensure_available!' do
    it 'does not know a channel that is not in the catalog' do
      expect(described_class.available?(account, 'ghost')).to be(false)
    end

    it 'raises with the Russian line and the channel key when the channel is not available' do
      expect { described_class.ensure_available!(account, 'api') }.to raise_error(Channels::NotAvailable) do |error|
        expect(error.channel_key).to eq('api')
        expect(error.message).to eq('Канал «API» недоступен для вашей клиники. Чтобы его подключить, обратитесь в поддержку.')
      end
    end

    it 'passes for an available channel' do
      expect(described_class.ensure_available!(account, 'website')).to be(true)
    end
  end
end
