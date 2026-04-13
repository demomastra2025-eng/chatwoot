FactoryBot.define do
  factory :llm_event_annotation do
    account
    llm_event { create(:llm_event, account: account) }
    user { create(:user, account: account, role: :administrator) }
    body { 'Investigating tool failure in staging-like conversation.' }
  end
end
