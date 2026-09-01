FactoryBot.define do
  factory :billing_organization do
    sequence(:name) { |n| "Billing organization #{n}" }
    status { :active }
  end
end
