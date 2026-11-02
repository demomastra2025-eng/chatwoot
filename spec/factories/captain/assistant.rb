FactoryBot.define do
  factory :captain_assistant, class: 'Captain::Assistant' do
    # Existing rows predate the canonical initializer. This fixture writes that
    # historical DB shape explicitly, without weakening production creation.
    trait :legacy do
      to_create { |assistant| assistant.save!(validate: false) }
    end

    sequence(:name) { |n| "Assistant #{n}" }
    description { 'Test description' }
    usage_mode { 'external_agent' }
    association :account
  end
end
