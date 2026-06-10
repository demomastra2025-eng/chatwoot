FactoryBot.define do
  factory :telephony_sip_profile, class: 'Telephony::SipProfile' do
    account
    inbox { create(:inbox, account: account) }
    user { create(:user, account: account, role: :agent) }
    provider_connection { create(:telephony_provider_connection, account: account) }
    sequence(:internal_extension) { |n| (200 + n).to_s }
    sip_username { "user-#{user.id}" }
    sip_host { provider_connection.host }
    agent_ref { SecureRandom.uuid }
    agent_aor { "sip:#{internal_extension}@#{sip_host}" }
    fonoster_agent_ref { agent_ref }
    credentials_ref { SecureRandom.uuid }
    enabled { true }
    availability_mode { 'external_extension' }
    status { 'draft' }
    managed_by { 'onelink' }
    ownership_status { 'local' }
    metadata { {} }
  end
end
