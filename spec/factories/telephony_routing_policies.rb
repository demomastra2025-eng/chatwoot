FactoryBot.define do
  factory :telephony_routing_policy, class: 'Telephony::RoutingPolicy' do
    account
    number_binding { create(:telephony_number_binding, account: account) }
    mode { 'operator' }
    operator_agent_aor { "sip:agent-#{SecureRandom.hex(4)}@example.test" }
    ai_enabled { false }
    fallback_mode { 'reject' }
    business_hours { {} }
    settings { {} }
  end
end
