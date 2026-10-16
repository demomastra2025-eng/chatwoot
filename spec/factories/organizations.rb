# frozen_string_literal: true

FactoryBot.define do
  factory :organization do
    sequence(:name) { |n| "Organization #{n}" }

    # Every requisite and the contract filled in; the BIN is a unique 12-digit number
    trait :with_requisites do
      sequence(:legal_name) { |n| "ТОО Организация #{n}" }
      sequence(:bin) { |n| format('9801%08d', n) }
      contract_number { 'ДГ-12' }
      contract_date { Date.new(2026, 3, 15) }
      billing_email { 'billing@example.test' }
      phone { '+7 727 000 00 00' }
      address { 'Алматы, ул. Абая, 1' }
      notes { 'Договор на год.' }
    end
  end
end
