FactoryBot.define do
  factory :crm_stage, class: 'Crm::Stage' do
    pipeline factory: :crm_pipeline
    account { pipeline.account }
    sequence(:name) { |n| "Stage #{n}" }
    sequence(:code) { |n| "stage_#{n}" }
    color { Crm::Stage::DEFAULT_COLOR }
    sequence(:position) { |n| n }
    outcome { 'open' }
    active { true }
  end
end
