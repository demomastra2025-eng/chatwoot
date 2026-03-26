FactoryBot.define do
  factory :crm_comment, class: 'Crm::Comment' do
    account
    association :commentable, factory: :crm_deal
    user { create(:user, account: account, role: :agent) }
    body { 'Initial CRM note' }
  end
end
