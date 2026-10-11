FactoryBot.define do
  factory :captain_inbox, class: 'CaptainInbox' do
    association :captain_assistant, factory: :captain_assistant
    association :inbox
    ai_enabled { true }
  end
end
