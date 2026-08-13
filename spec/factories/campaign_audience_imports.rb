FactoryBot.define do
  factory :campaign_audience_import do
    account
    inbox { create(:inbox, account: account, channel: create(:channel_sms, account: account)) }
    created_by { create(:user, account: account, role: :administrator) }
    sequence(:token) { |n| "audience-token-#{n}" }
    source_filename { 'recipients.csv' }
    default_country { 'KZ' }
    status { :completed }
    expires_at { 1.hour.from_now }
  end

  factory :campaign_audience_recipient do
    campaign_audience_import
    account { campaign_audience_import.account }
    contact { create(:contact, account: account, phone_number: normalized_phone_number) }
    sequence(:normalized_phone_number) { |n| "+7705000#{format('%04d', n)}" }
    sequence(:source_row, 2)
  end
end
