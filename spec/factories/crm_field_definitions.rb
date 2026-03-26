FactoryBot.define do
  factory :crm_field_definition, class: 'Crm::FieldDefinition' do
    account
    entity_kind { 'deal' }
    sequence(:key) { |n| "custom_field_#{n}" }
    sequence(:label) { |n| "Custom Field #{n}" }
    field_type { 'text' }
    required { false }
    active { true }
    sequence(:position) { |n| n }
    default_value { nil }
    options { [] }
    rules { {} }
  end
end
