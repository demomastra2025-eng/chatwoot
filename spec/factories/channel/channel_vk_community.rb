FactoryBot.define do
  factory :channel_vk_community, class: 'Channel::VkCommunity' do
    account
    sequence(:group_id) { |n| 900_000 + n }
    access_token { SecureRandom.hex(16) }
    secret { SecureRandom.hex(8) }
    confirmation_token { SecureRandom.hex(12) }
    api_version { '5.199' }
    sequence(:callback_id) { |n| "vk-callback-#{n}" }

    after(:create) do |channel|
      create(:inbox, channel: channel, account: channel.account)
    end
  end
end
