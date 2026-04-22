require 'rails_helper'
require 'stringio'

RSpec.describe TelegramPersonal::SyncProfileAvatarJob do
  include ActiveJob::TestHelper

  around do |example|
    with_modified_env(
      'TELEGRAM_PERSONAL_GATEWAY_URL' => 'https://telegram-gateway.example.com',
      'TELEGRAM_PERSONAL_GATEWAY_TOKEN' => 'test-gateway-token',
      'FRONTEND_URL' => 'https://app.example.com'
    ) do
      example.run
    end
  end

  let(:account) { create(:account, limits: { non_web_inboxes: ChatwootApp.max_limit, storage_bytes: 10.megabytes }) }
  let(:channel) { create(:channel_telegram_personal, account: account, phone_number: '+77001234567') }
  let(:contact) { create(:contact, account: account, name: 'Sojan Jose') }
  let(:contact_inbox) { create(:contact_inbox, inbox: channel.inbox, contact: contact, source_id: '23') }
  let(:profile) do
    create(
      :contact_channel_profile,
      contact_inbox: contact_inbox,
      contact: contact,
      inbox: channel.inbox,
      account: account,
      provider: 'telegram_personal',
      source_id: '23',
      profile_data: {
        'identifier' => 'telegram_personal:23',
        'source_id' => '23',
        'avatar_fingerprint' => 'telegram-photo-23'
      },
      last_synced_at: nil
    )
  end

  it 'enqueues on the default queue' do
    expect { described_class.perform_later(profile.id, 'telegram-photo-23') }
      .to have_enqueued_job(described_class).with(profile.id, 'telegram-photo-23').on_queue('default')
  end

  it 'downloads avatar bytes from the gateway and attaches them to the channel profile' do
    gateway_client = instance_double(TelegramPersonal::GatewayClient)

    expect(TelegramPersonal::GatewayClient).to receive(:new).with(channel: channel).and_return(gateway_client)
    expect(gateway_client).to receive(:fetch_profile_avatar!).with(
      peer_user_id: '23',
      avatar_fingerprint: 'telegram-photo-23'
    ).and_return(
      body: File.binread(Rails.root.join('spec/assets/avatar.png')),
      content_type: 'image/png'
    )

    described_class.perform_now(profile.id, 'telegram-photo-23')

    expect(profile.reload.avatar).to be_attached
    expect(profile.avatar.blob.content_type).to eq('image/png')
    expect(profile.avatar.blob.metadata[described_class::AVATAR_FINGERPRINT_METADATA_KEY]).to eq('telegram-photo-23')
    expect(profile.last_synced_at).to be_present
  end

  it 'returns early when the matching avatar is already attached' do
    profile.avatar.attach(
      io: StringIO.new(File.binread(Rails.root.join('spec/assets/avatar.png'))),
      filename: 'avatar.png',
      content_type: 'image/png',
      metadata: {
        described_class::AVATAR_FINGERPRINT_METADATA_KEY => 'telegram-photo-23'
      }
    )

    expect(TelegramPersonal::GatewayClient).not_to receive(:new)

    described_class.perform_now(profile.id, 'telegram-photo-23')
  end

  it 'refreshes the avatar when the attached blob metadata has an older fingerprint' do
    profile.avatar.attach(
      io: StringIO.new(File.binread(Rails.root.join('spec/assets/avatar.png'))),
      filename: 'avatar.png',
      content_type: 'image/png',
      metadata: {
        described_class::AVATAR_FINGERPRINT_METADATA_KEY => 'telegram-photo-23'
      }
    )
    profile.update!(
      profile_data: profile.profile_data.merge('avatar_fingerprint' => 'telegram-photo-99')
    )

    gateway_client = instance_double(TelegramPersonal::GatewayClient)
    expect(TelegramPersonal::GatewayClient).to receive(:new).with(channel: channel).and_return(gateway_client)
    expect(gateway_client).to receive(:fetch_profile_avatar!).with(
      peer_user_id: '23',
      avatar_fingerprint: 'telegram-photo-99'
    ).and_return(
      body: File.binread(Rails.root.join('spec/assets/avatar.png')),
      content_type: 'image/png'
    )

    described_class.perform_now(profile.id, 'telegram-photo-99')

    expect(profile.reload.avatar.blob.metadata[described_class::AVATAR_FINGERPRINT_METADATA_KEY]).to eq('telegram-photo-99')
  end

  it 'skips avatar sync without raising when the account storage limit is exceeded' do
    profile.update!(last_synced_at: 2.days.ago)
    account.update!(limits: account.limits.merge('storage_bytes' => 1))

    gateway_client = instance_double(TelegramPersonal::GatewayClient)
    expect(TelegramPersonal::GatewayClient).to receive(:new).with(channel: channel).and_return(gateway_client)
    expect(gateway_client).to receive(:fetch_profile_avatar!).with(
      peer_user_id: '23',
      avatar_fingerprint: 'telegram-photo-23'
    ).and_return(
      body: 'ab',
      content_type: 'image/png'
    )

    expect do
      described_class.perform_now(profile.id, 'telegram-photo-23')
    end.not_to raise_error

    profile.reload
    expect(profile.avatar).not_to be_attached
    expect(profile.last_synced_at).to be_within(1.second).of(2.days.ago)
  end
end
