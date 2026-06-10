FactoryBot.define do
  factory :telephony_provider_connection, class: 'Telephony::ProviderConnection' do
    account
    provider_kind { 'sipuni' }
    sequence(:name) { |n| "Sipuni connection #{n}" }
    host { 'ats01.kz.sipuni.com' }
    port { 5060 }
    transport { 'udp' }
    username { '056124100014' }
    credentials_ref { SecureRandom.uuid }
    fonoster_trunk_ref { SecureRandom.uuid }
    send_register { false }
    status { 'draft' }
    managed_by { 'onelink' }
    ownership_status { 'local' }
    metadata { {} }
  end
end
