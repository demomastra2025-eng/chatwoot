FactoryBot.define do
  factory :campaign_delivery do
    campaign
    account { campaign.account }
    inbox { campaign.inbox }
    contact { create(:contact, :with_phone_number, account: campaign.account) }
    provider { 'twilio_sms' }
    target_identifier { contact.phone_number }
    status { 'pending' }
    metadata { {} }
  end
end
