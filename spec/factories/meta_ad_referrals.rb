# frozen_string_literal: true

FactoryBot.define do
  factory :meta_ad_referral do
    account
    inbox { association(:inbox, account: account) }
    provider { 'whatsapp' }
    sequence(:provider_message_id) { |n| "meta-referral-#{n}" }
    attribution_type { 'click_to_whatsapp_ad' }
    received_at { Time.current }
  end
end
