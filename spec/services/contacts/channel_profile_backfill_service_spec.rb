require 'rails_helper'

RSpec.describe Contacts::ChannelProfileBackfillService do
  it 'backfills a profile for an existing twitter contact inbox' do
    channel = create(:channel_twitter_profile)
    inbox = create(:inbox, channel: channel, account: channel.account)
    contact = create(
      :contact,
      account: channel.account,
      name: 'SurveyJoy',
      additional_attributes: {
        'screen_name' => 'surveyjoyHQ',
        'profile_image_url' => 'https://chatwoot-assets.local/twitter.png',
        'location' => 'Bangalore'
      }
    )
    contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox, source_id: '2')

    result = described_class.new(scope: ContactInbox.where(id: contact_inbox.id)).perform

    expect(result.created_count).to eq(1)
    expect(contact_inbox.reload.channel_profile).to have_attributes(
      provider: 'twitter_profile',
      display_name: 'SurveyJoy',
      username: 'surveyjoyHQ',
      avatar_url: 'https://chatwoot-assets.local/twitter.png'
    )
    expect(contact_inbox.channel_profile.profile_data).to include(
      'screen_name' => 'surveyjoyHQ',
      'location' => 'Bangalore'
    )
  end

  it 'skips existing channel profiles by default' do
    contact_inbox = create(:contact_inbox)
    create(:contact_channel_profile, contact_inbox: contact_inbox, display_name: 'Original Name')

    result = described_class.new(scope: ContactInbox.where(id: contact_inbox.id)).perform

    expect(result.skipped_count).to eq(1)
    expect(contact_inbox.reload.channel_profile.display_name).to eq('Original Name')
  end

  it 'does not guess when legacy provider profiles are ambiguous' do
    channel = create(:channel_twitter_profile)
    inbox = create(:inbox, channel: channel, account: channel.account)
    contact = create(
      :contact,
      account: channel.account,
      name: 'SurveyJoy',
      additional_attributes: {
        'channel_profiles' => {
          'twitter_profile' => {
            'legacy-a' => {
              'screen_name' => 'wrong_a',
              'profile_image_url' => 'https://chatwoot-assets.local/a.png'
            },
            'legacy-b' => {
              'screen_name' => 'wrong_b',
              'profile_image_url' => 'https://chatwoot-assets.local/b.png'
            }
          }
        }
      }
    )
    contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox, source_id: '2')
    logger = instance_double(Logger, error: nil, warn: nil)

    result = described_class.new(scope: ContactInbox.where(id: contact_inbox.id), logger: logger).perform

    expect(result.created_count).to eq(1)
    expect(logger).to have_received(:warn).with(include('Ambiguous legacy profile'))
    expect(contact_inbox.reload.channel_profile.display_name).to eq('SurveyJoy')
    expect(contact_inbox.channel_profile.username).to be_nil
    expect(contact_inbox.channel_profile.avatar_url).to be_nil
    expect(contact_inbox.channel_profile.profile_data).not_to include(
      'screen_name' => 'wrong_a'
    )
    expect(contact_inbox.channel_profile.profile_data).not_to include(
      'screen_name' => 'wrong_b'
    )
  end
end
