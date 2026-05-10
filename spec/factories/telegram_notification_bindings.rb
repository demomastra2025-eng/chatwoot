# frozen_string_literal: true

FactoryBot.define do
  factory :telegram_notification_binding do
    user

    trait :connected do
      telegram_user_id { SecureRandom.random_number(1_000_000_000).to_s }
      telegram_chat_id { telegram_user_id }
      username { 'agent' }
      verified_at { Time.current }
    end
  end
end
