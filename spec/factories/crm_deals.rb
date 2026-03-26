FactoryBot.define do
  factory :crm_deal, class: 'Crm::Deal' do
    account
    title { 'Enterprise renewal' }
    description { 'Quarterly expansion' }

    after(:build) do |deal|
      deal.pipeline ||= create(:crm_pipeline, account: deal.account)
      deal.stage ||= create(:crm_stage, account: deal.account, pipeline: deal.pipeline)
    end
  end
end
