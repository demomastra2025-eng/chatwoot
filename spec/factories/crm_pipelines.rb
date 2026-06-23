FactoryBot.define do
  factory :crm_pipeline, class: 'Crm::Pipeline' do
    account
    sequence(:name) { |n| "Pipeline #{n}" }
    sequence(:code) { |n| "pipeline_#{n}" }
    sequence(:position) { |n| n }
    active { true }
    default { false }
    auto_create_deal_on_channel_contact { false }
  end
end
