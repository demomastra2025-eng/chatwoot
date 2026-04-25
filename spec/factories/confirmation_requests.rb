# frozen_string_literal: true

FactoryBot.define do
  factory :confirmation_request do
    account
    conversation { association :conversation, account: account }
    contact { conversation&.contact }
    inbox { conversation&.inbox }
    title { 'Подтверждение' }
    body { 'Пожалуйста, подтвердите действие.' }
    status { 'pending' }
    token { SecureRandom.urlsafe_base64(24) }
    expires_at { 1.day.from_now }
    metadata { {} }
    resolution_metadata { {} }
  end
end
