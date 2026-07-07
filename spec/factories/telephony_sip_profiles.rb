FactoryBot.define do
  factory :telephony_sip_profile, class: 'Telephony::SipProfile' do
    account
    inbox { create(:inbox, account: account) }
    user { create(:user, account: account, role: :agent) }
    provider_connection { create(:telephony_provider_connection, account: account) }
    profile_kind { 'human_operator' }
    sequence(:internal_extension) { |n| (200 + n).to_s }
    sip_username { "user-#{user.id}" }
    sip_host { provider_connection.host }
    agent_ref { SecureRandom.uuid }
    agent_aor { "sip:#{internal_extension}@#{sip_host}" }
    fonoster_agent_ref { nil }
    credentials_ref { SecureRandom.uuid }
    enabled { true }
    availability_mode { 'external_extension' }
    status { 'draft' }
    managed_by { 'onelink' }
    ownership_status { 'local' }
    metadata { {} }

    trait :voice_agent do
      profile_kind { 'voice_agent' }
      user { nil }
      sequence(:internal_extension) { |n| (9000 + n).to_s }
      sip_username { "voice-agent-#{internal_extension}" }
      sip_password { 'voice-agent-secret' }
      credentials_ref { nil }
      agent_ref { "profile-#{account.id}-voice-agent-#{internal_extension}" }
    end
  end
end
