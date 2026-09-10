FactoryBot.define do
  factory :access_role_grant do
    account
    access_role { association :access_role, account: account }
    resource { 'contacts' }
    capability { 'view' }
    access_scope { 'own' }
  end
end
