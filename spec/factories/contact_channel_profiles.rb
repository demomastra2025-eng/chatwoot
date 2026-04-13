FactoryBot.define do
  factory :contact_channel_profile do
    contact_inbox
    contact { contact_inbox.contact }
    inbox { contact_inbox.inbox }
    account { inbox.account }
    channel_type { inbox.channel_type }
    provider { inbox.channel_type.demodulize.underscore }
    source_id { contact_inbox.source_id }
    display_name { 'Channel Contact' }
    avatar_url { 'https://chatwoot-assets.local/channel-avatar.png' }
    profile_data { {} }
    last_synced_at { Time.current }
  end
end
