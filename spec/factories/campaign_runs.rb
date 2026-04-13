FactoryBot.define do
  factory :campaign_run do
    campaign
    account { campaign.account }
    inbox { campaign.inbox }
    status { 'queued' }
    total_count { 0 }
    processed_count { 0 }
    successful_count { 0 }
    failed_count { 0 }
    skipped_count { 0 }
    metadata { {} }
  end
end
