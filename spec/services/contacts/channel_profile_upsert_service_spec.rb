require 'rails_helper'

RSpec.describe Contacts::ChannelProfileUpsertService do
  let(:contact_inbox) { create(:contact_inbox, source_id: 'telegram-peer-1') }

  it 'creates a channel profile for a contact inbox', :aggregate_failures do
    profile = described_class.new(
      contact_inbox: contact_inbox,
      provider: 'telegram_personal',
      profile_attributes: {
        name: 'Telegram Name',
        username: 'telegram_user',
        avatar_url: 'https://chatwoot-assets.local/avatar.png',
        phone_number: '+77011234567',
        additional_attributes: {
          language_code: 'ru',
          social_telegram_user_id: 123
        }
      }
    ).perform

    expect(profile).to be_persisted
    expect(profile.contact).to eq(contact_inbox.contact)
    expect(profile.inbox).to eq(contact_inbox.inbox)
    expect(profile.account).to eq(contact_inbox.inbox.account)
    expect(profile.provider).to eq('telegram_personal')
    expect(profile.source_id).to eq('telegram-peer-1')
    expect(profile.display_name).to eq('Telegram Name')
    expect(profile.username).to eq('telegram_user')
    expect(profile.avatar_url).to eq('https://chatwoot-assets.local/avatar.png')
    expect(profile.phone_number).to eq('+77011234567')
    expect(profile.profile_data).to include(
      'language_code' => 'ru',
      'social_telegram_user_id' => 123
    )
  end

  it 'updates the same profile without clearing existing values when a partial payload arrives' do
    described_class.new(
      contact_inbox: contact_inbox,
      profile_attributes: {
        name: 'Original Name',
        avatar_url: 'https://chatwoot-assets.local/avatar.png'
      }
    ).perform

    profile = described_class.new(
      contact_inbox: contact_inbox,
      profile_attributes: {
        username: 'new_username'
      }
    ).perform

    expect(ContactChannelProfile.where(contact_inbox: contact_inbox).count).to eq(1)
    expect(profile.display_name).to eq('Original Name')
    expect(profile.avatar_url).to eq('https://chatwoot-assets.local/avatar.png')
    expect(profile.username).to eq('new_username')
  end
end
