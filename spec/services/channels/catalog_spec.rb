# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Channels::Catalog do
  # The tiles of ChannelList.vue; WhatsApp and Telegram stand for several catalog channels
  let(:channel_list_tiles) do
    %w[website facebook twitter whatsapp sms email api telegram weixin vk_community line instagram tiktok voice]
  end
  let(:channel_models) do
    Dir[Rails.root.join('{app,enterprise/app}/models/channel/*.rb')].map { |path| "Channel::#{File.basename(path, '.rb').camelize}" }
  end

  it 'has unique keys' do
    expect(described_class.keys.tally.select { |_key, count| count > 1 }).to be_empty
  end

  it 'covers every tile of the operator app channel list' do
    expect(described_class.entries.map(&:tile).uniq).to match_array(channel_list_tiles)
  end

  it 'gives the WhatsApp and Telegram choices their own switches' do
    expect(described_class.entries.select { |entry| entry.tile == 'whatsapp' }.map(&:key))
      .to match_array(%w[whatsapp_cloud whatsapp_twilio whatsapp_web])
    expect(described_class.entries.select { |entry| entry.tile == 'telegram' }.map(&:key))
      .to match_array(%w[telegram_bot telegram_personal])
  end

  it 'hides Twitter, WeChat, LINE, VK, TikTok, SMS and API by default and shows everything else' do
    hidden = described_class.entries.reject(&:shown_by_default?).map(&:key)

    expect(hidden).to match_array(%w[twitter weixin line vk_community tiktok sms api])
    expect(described_class.default_state('facebook')).to eq('shown')
    expect(described_class.default_state('telegram_personal')).to eq('shown')
    expect(described_class.default_state('voice')).to eq('shown')
  end

  it 'names only feature flags that exist' do
    flags = described_class.entries.filter_map(&:flag)

    expect(flags).to include('channel_website', 'channel_facebook', 'channel_instagram', 'channel_tiktok', 'channel_email', 'channel_voice')
    expect(flags - Featurable::FEATURE_NAMES).to be_empty
  end

  it 'has a Russian name and at least one guarded creation path for every channel' do
    described_class.entries.each do |entry|
      expect(I18n.t("super_admin.channels.names.#{entry.key}", locale: :ru, default: nil)).to be_present, "no Russian name for #{entry.key}"
      expect(entry.creation).not_to be_empty
      expect(entry.inbox_types).not_to be_empty
    end
  end

  it 'covers every channel model of the application' do
    mapped = described_class.entries.flat_map(&:inbox_types).uniq

    expect(channel_models - mapped).to be_empty
    expect(mapped - channel_models).to be_empty
  end

  describe '.key_for_create' do
    it 'maps every channel type the inbox endpoint creates' do
      endpoint_types = Api::V1::Accounts::InboxesController.new.send(:allowed_channel_types)

      expect(endpoint_types - described_class::CREATE_TYPES.keys).to be_empty
      expect(described_class::CREATE_TYPES.values - described_class.keys).to be_empty
    end

    it 'maps the types to the catalog keys of their choice' do
      expect(described_class.key_for_create('telegram')).to eq('telegram_bot')
      expect(described_class.key_for_create('whatsapp')).to eq('whatsapp_cloud')
      expect(described_class.key_for_create('web_widget')).to eq('website')
    end

    it 'knows nothing about a type the endpoint does not create' do
      expect(described_class.key_for_create('linkedin_personal')).to be_nil
      expect(described_class.key_for_create(nil)).to be_nil
    end
  end

  describe '.key_for_inbox_type' do
    it 'maps every inbox channel type to a catalog key that lists it' do
      described_class.entries.flat_map(&:inbox_types).uniq.each do |type|
        key = described_class.key_for_inbox_type(type, medium: 'sms')

        expect(described_class.find(key).inbox_types).to include(type)
      end
    end

    it 'tells the two Twilio channels apart by their medium' do
      expect(described_class.key_for_inbox_type('Channel::TwilioSms', medium: 'whatsapp')).to eq('whatsapp_twilio')
      expect(described_class.key_for_inbox_type('Channel::TwilioSms', medium: 'sms')).to eq('sms')
    end

    it 'folds the legacy 360dialog provider into WhatsApp Cloud API and Bandwidth into SMS' do
      expect(described_class.key_for_inbox_type('Channel::Whatsapp')).to eq('whatsapp_cloud')
      expect(described_class.key_for_inbox_type('Channel::Sms')).to eq('sms')
    end

    it 'does not know a retired channel' do
      expect(described_class.key_for_inbox_type('Channel::LinkedinPersonal')).to be_nil
    end
  end

  describe '.unavailable_message' do
    it 'is a Russian line that names the channel' do
      expect(described_class.unavailable_message('api'))
        .to eq('Канал «API» недоступен для вашего аккаунта. Чтобы его подключить, обратитесь в поддержку.')
    end
  end

  describe '.fetch' do
    it 'raises for an unknown channel' do
      expect { described_class.fetch('ghost') }.to raise_error(ArgumentError, /Unknown channel/)
    end
  end
end
