require 'rails_helper'
require 'stringio'

RSpec.describe TelegramPersonal::SyncProfileAvatarJob do
  include ActiveJob::TestHelper

  let(:account) { create(:account, limits: { non_web_inboxes: ChatwootApp.max_limit }) }
  let(:channel) { create(:channel_telegram_personal, account: account, phone_number: '+77066318623') }
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
end
