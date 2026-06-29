FactoryBot.define do
  factory :lead_form do
    account
    inbox { create(:inbox, account: account) }
    sequence(:name) { |n| "Lead form #{n}" }
    source_kind { 'api' }
    status { 'active' }
    field_schema do
      [
        { 'name' => 'full_name', 'label' => 'Name', 'type' => 'text', 'required' => true },
        { 'name' => 'phone_number', 'label' => 'Phone', 'type' => 'text', 'required' => true }
      ]
    end
    settings { { 'conversation_status' => 'open' } }
  end

  factory :lead_submission do
    account
    lead_form { create(:lead_form, account: account) }
    inbox { lead_form.inbox }
    source_kind { lead_form.source_kind }
    status { 'received' }
    field_values { { 'full_name' => 'Lead Client', 'phone_number' => '+77010000000' } }
  end
end
