require 'rails_helper'

RSpec.describe Telephony::RoutingPolicy, type: :model do
  subject(:policy) do
    build(:telephony_routing_policy, account: account, number_binding: number_binding, settings: settings)
  end

  let(:account) { create(:account) }
  let(:number_binding) { create(:telephony_number_binding, account: account) }
  let(:settings) { {} }

  describe '.public_call_routing' do
    it 'preserves supported scalar strings as canonical public values without changing stored settings' do
      raw = {
        'show_extended_call_card' => 'false',
        'inbound' => {
          'ring_timeout_seconds' => '47', 'skip_busy_operators' => '0',
          'groups' => [{ 'id' => 'team', 'ring_seconds' => '25', 'user_ids' => ['7'] }],
          'whatsapp_followup' => { 'enabled' => 'false', 'cooldown_minutes' => '60' },
          'archive' => { 'system_prompt' => 'PRIVATE_SCALAR_ROUTING_ARCHIVE' }
        },
        'outbound' => { 'allowed_user_ids' => ['7'] }
      }
      policy.settings = { 'call_routing' => raw }
      snapshot = policy.settings.deep_dup

      expect(policy.to_telephony_h.dig(:settings, 'call_routing')).to eq(
        'show_extended_call_card' => false,
        'inbound' => {
          'ring_timeout_seconds' => 47, 'skip_busy_operators' => false,
          'groups' => [{ 'id' => 'team', 'ring_seconds' => 25, 'user_ids' => [7] }],
          'whatsapp_followup' => { 'enabled' => false, 'cooldown_minutes' => 60 }
        },
        'outbound' => { 'allowed_user_ids' => [7] }
      )
      expect(policy.settings).to eq(snapshot)
    end

    it 'rejects malformed and nonfinite numbers and never casts objects or arrays to scalars' do
      raw = {
        'show_extended_call_card' => [],
        'inbound' => {
          'ring_timeout_seconds' => '47junk', 'skip_busy_operators' => { 'archive' => 'PRIVATE_SCALAR_ROUTING_ARCHIVE' },
          'groups' => [{ 'ring_seconds' => '1e309', 'user_ids' => ['NaN', '1e309', {}, [], '7'] }],
          'archive' => { 'system_prompt' => 'PRIVATE_SCALAR_ROUTING_ARCHIVE' }
        }
      }

      expect(described_class.public_call_routing(raw)).to eq('inbound' => { 'groups' => [{ 'user_ids' => [7] }] })
    end
  end

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

  it 'acquires the shared voice assignment lock when the Captain assistant changes' do
    policy.save!
    assistant = create(:captain_assistant, account: account)

    expect(Telephony::AiVoice::AssistantAssignmentLock).to receive(:acquire!).with(number_binding.inbox_id).and_call_original

    policy.update!(captain_assistant: assistant)
  end
end
