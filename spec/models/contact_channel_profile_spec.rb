# frozen_string_literal: true

require 'rails_helper'
require 'stringio'

RSpec.describe ContactChannelProfile do
  around do |example|
    with_modified_env('FRONTEND_URL' => 'https://app.example.com') do
      example.run
    end
  end

  let(:profile) do
    create(
      :contact_channel_profile,
      provider: 'telegram_personal',
      avatar_url: 'https://app.one-link.kz/telegram-personal/media/avatar-1?token=temporary',
      profile_data: {
        'avatar_fingerprint' => 'telegram-photo-1',
        'profile_photo_url' => 'https://app.one-link.kz/telegram-personal/media/avatar-1?token=temporary'
      }
    )
  end

  it 'hides transient telegram personal avatar urls until a stable avatar is attached' do
    expect(profile.avatar_url).to be_nil
    expect(profile.push_event_data[:avatar_url]).to be_nil
    expect(profile.push_event_data[:profile_data]).not_to have_key('profile_photo_url')

    profile.avatar.attach(
      io: StringIO.new(File.binread(Rails.root.join('spec/assets/avatar.png'))),
      filename: 'avatar.png',
      content_type: 'image/png'
    )

    expect(profile.avatar_url).to match(%r{rails/active_storage/representations/redirect/.*/avatar\.png})
    expect(profile.push_event_data[:avatar_url]).to match(%r{rails/active_storage/representations/redirect/.*/avatar\.png})
    expect(profile.push_event_data[:profile_data]).not_to have_key('profile_photo_url')
  end
end
