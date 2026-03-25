FactoryBot.define do
  factory :crm_stage, class: 'Crm::Stage' do
    pipeline factory: :crm_pipeline
    account { pipeline.account }
    sequence(:name) { |n| "Stage #{n}" }
    sequence(:code) { |n| "stage_#{n}" }
    sequence(:position) { |n| n }
    outcome { 'open' }
    active { true }
  end
end
