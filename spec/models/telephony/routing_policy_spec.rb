require 'rails_helper'

RSpec.describe Telephony::RoutingPolicy, type: :model do
  subject(:policy) do
    build(:telephony_routing_policy, account: account, number_binding: number_binding, settings: settings)
  end

  let(:account) { create(:account) }
  let(:number_binding) { create(:telephony_number_binding, account: account) }
  let(:settings) { {} }

  it 'defaults the channel call duration limit to 30 minutes' do
    expect(policy.max_call_duration_seconds).to eq(1800)
  end

  it 'persists a valid channel call duration limit in settings' do
    policy.max_call_duration_seconds = 3600

    expect(policy).to be_valid
    expect(policy.settings['max_call_duration_seconds']).to eq(3600)
    expect(policy.max_call_duration_seconds).to eq(3600)
  end

  it 'rejects call duration limits outside the safe range' do
    policy.max_call_duration_seconds = 120

    expect(policy).not_to be_valid
    expect(policy.errors[:max_call_duration_seconds]).to be_present
  end
end
