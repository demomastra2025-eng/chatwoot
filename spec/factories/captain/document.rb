FactoryBot.define do
  factory :captain_document, class: 'Captain::Document' do
    name { Faker::File.file_name }
    external_link { Faker::Internet.unique.url }
    content { Faker::Lorem.paragraphs.join("\n\n") }
    association :account
    assistant { association(:captain_assistant, account: account) }

    after(:build) do |document|
      document.account = document.assistant.account if document.assistant.present?
    end
  end
end
