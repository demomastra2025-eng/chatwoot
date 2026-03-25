FactoryBot.define do
  factory :crm_deal_contact, class: 'Crm::DealContact' do
    deal { create(:crm_deal) }
    account { deal.account }
    contact { create(:contact, :with_email, account: account) }
    primary { false }
  end
end
