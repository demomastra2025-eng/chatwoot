FactoryBot.define do
  factory :channel_weixin, class: 'Channel::Weixin' do
    account
    sequence(:ilink_token) { |n| "test-ilink-token-#{n}" }
    sequence(:provider_account_id) { |n| "wxid_test_#{n}" }
    sequence(:display_name) { |n| "Weixin Test #{n}" }
    connection_state { 'disconnected' }
    lifecycle_state { 'pending_auth' }
    runtime_state { {} }

    after(:create) do |channel|
      create(:inbox, channel: channel, account: channel.account)
    end
  end
end
