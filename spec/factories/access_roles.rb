FactoryBot.define do
  factory :access_role do
    account
    sequence(:name) { |index| "Access role #{index}" }
  end
end
