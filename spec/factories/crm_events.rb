FactoryBot.define do
  factory :crm_event, class: 'Crm::Event' do
    account
    eventable { create(:crm_deal, account: account) }
    actor { create(:user, account: account, role: :administrator) }
    event_type { 'deal_created' }
    meta { {} }
    created_at { Time.zone.now }
  end
end
