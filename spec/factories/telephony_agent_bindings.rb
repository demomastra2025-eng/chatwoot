FactoryBot.define do
  factory :telephony_agent_binding, class: 'Telephony::AgentBinding' do
    account
    user { create(:user, account: account, role: :agent) }
    provider { 'sipuni' }
    agent_ref { SecureRandom.uuid }
    agent_aor { "sip:#{user.id}@voice.example" }
    domain_ref { SecureRandom.uuid }
    credentials_ref { SecureRandom.uuid }
    enabled { true }
    metadata { {} }

    trait :registered do
      last_synced_at { Time.current }
      metadata do
        {
          registration_state: 'registered',
          presence: 'online'
        }
      end
    end
  end
end
