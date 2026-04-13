FactoryBot.define do
  factory :channel_telegram_personal, class: 'Channel::TelegramPersonal' do
    account
    sequence(:api_id) { |n| 100_000 + n }
    api_hash { SecureRandom.hex(16) }
    sequence(:phone_number) { |n| "+7701555#{format('%04d', n)}" }
    connection_state { 'disconnected' }
    lifecycle_state { 'pending_auth' }
    runtime_state { {} }

    after(:create) do |channel|
      create(:inbox, channel: channel, account: channel.account)
    end
  end
end
