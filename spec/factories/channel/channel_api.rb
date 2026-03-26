FactoryBot.define do
  factory :channel_api, class: 'Channel::Api' do
    webhook_url { 'http://example.com' }
    account

    trait :whatsapp_web_provider do
      additional_attributes do
        {
          'provider' => Channel::Api::WHATSAPP_WEB_PROVIDER,
          'number' => '77066318623'
        }
      end
    end

    after(:create) do |channel_api|
      create(:inbox, channel: channel_api, account: channel_api.account)
    end
  end
end
