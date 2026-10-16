# frozen_string_literal: true

FactoryBot.define do
  factory :organization do
    sequence(:name) { |n| "Organization #{n}" }

    # Every requisite and the contract filled in; the BIN is a unique 12-digit number with a valid control digit
    trait :with_requisites do
      sequence(:legal_name) { |n| "ТОО Организация #{n}" }
      sequence(:bin) do |n|
        # The 11th digit is picked so that the control digit exists (a remainder of 10 twice has none)
        first_ten = format('98%08d', n)
        eleventh = (0..9).find { |digit| Organization.bin_control_digit("#{first_ten}#{digit}") }
        first_eleven = "#{first_ten}#{eleventh}"
        "#{first_eleven}#{Organization.bin_control_digit(first_eleven)}"
      end
      contract_number { 'ДГ-12' }
      contract_date { Date.new(2026, 3, 15) }
      billing_email { 'billing@example.test' }
      phone { '+7 727 000 00 00' }
      address { 'Алматы, ул. Абая, 1' }
      notes { 'Договор на год.' }
    end
  end
end
