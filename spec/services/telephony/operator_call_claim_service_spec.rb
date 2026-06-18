require 'rails_helper'

RSpec.describe Telephony::OperatorCallClaimService do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:winner_user) { create(:user, account: account, role: :agent) }
  let(:other_user) { create(:user, account: account, role: :agent) }
  let(:outsider_user) { create(:user, account: account, role: :agent) }
  let!(:winner_member) { create(:inbox_member, inbox: inbox, user: winner_user) }
  let!(:other_member) { create(:inbox_member, inbox: inbox, user: other_user) }
  let!(:winner_binding) do
    create(
      :telephony_agent_binding,
      :registered,
      account: account,
      user: winner_user,
      agent_ref: 'agent-1001',
      agent_aor: 'sip:1001@voice.example'
    )
  end
  let!(:other_binding) do
    create(
      :telephony_agent_binding,
      :registered,
      account: account,
      user: other_user,
      agent_ref: 'agent-1002',
      agent_aor: 'sip:1002@voice.example'
    )
  end
  let(:route_metadata) do
    {
      'route_action' => 'operator',
      'operator_pool' => true,
      'operator_pool_size' => 2,
      'operator_candidate_binding_ids' => [winner_binding.id, other_binding.id],
      'operator_candidate_user_ids' => [winner_user.id, other_user.id],
      'operator_candidate_agent_refs' => [winner_binding.agent_ref, other_binding.agent_ref]
    }
  end
  let(:call_session) do
    create(
      :telephony_call_session,
      account: account,
      inbox: inbox,
      direction: 'inbound',
      status: 'ringing',
      metadata: { 'metadata' => route_metadata }
    )
  end

  it 'claims an operator pool call for an eligible registered candidate' do
    payload = described_class.new(account: account, user: winner_user, call_ref: call_session.external_call_ref).perform

    expect(payload).to include(
      call_ref: call_session.external_call_ref,
      status: 'connecting',
      claimed: true,
      agent_ref: winner_binding.agent_ref,
      agent_aor: winner_binding.agent_aor,
      agent_binding_id: winner_binding.id,
      user_id: winner_user.id,
      user_name: winner_user.name
    )

    call_session.reload
    expect(call_session.agent_binding_id).to eq(winner_binding.id)
    expect(call_session.answered_by).to eq("user:#{winner_user.id}")
    expect(call_session.metadata.dig('operator_claim', 'agent_binding_id')).to eq(winner_binding.id)
    expect(call_session.metadata.dig('operator_claim', 'user_name')).to eq(winner_user.name)
    expect(call_session.metadata.dig('metadata', 'operator_pool')).to be(true)
  end

  it 'claims a per-inbox SIP profile candidate without using the account-level binding' do
    profile = create(
      :telephony_sip_profile,
      account: account,
      inbox: inbox,
      user: winner_user,
      internal_extension: '504',
      agent_ref: 'profile-local-504',
      fonoster_agent_ref: 'fonoster-profile-504',
      agent_aor: 'sip:504@ats01.kz.sipuni.com'
    )
    call_session.update!(
      metadata: {
        'metadata' => {
          'route_action' => 'operator',
          'operator_pool' => true,
          'operator_candidate_sip_profile_ids' => [profile.id],
          'operator_candidate_user_ids' => [winner_user.id],
          'operator_candidate_agent_refs' => [profile.fonoster_agent_ref],
          'operator_candidate_agent_aors' => [profile.agent_aor],
          'operator_candidate_sources' => ['sip_profile']
        }
      }
    )

    payload = described_class.new(account: account, user: winner_user, call_ref: call_session.external_call_ref).perform

    expect(payload).to include(
      call_ref: call_session.external_call_ref,
      status: 'connecting',
      claimed: true,
      agent_ref: profile.fonoster_agent_ref,
      agent_aor: profile.agent_aor,
      sip_profile_id: profile.id,
      user_id: winner_user.id
    )
    expect(payload).not_to have_key(:agent_binding_id)

    call_session.reload
    expect(call_session.agent_binding_id).to be_nil
    expect(call_session.metadata.dig('operator_claim', 'sip_profile_id')).to eq(profile.id)
    expect(call_session.metadata.dig('operator_claim', 'agent_binding_id')).to be_nil
    expect(call_session.metadata.dig('operator_claim', 'agent_aor')).to eq('sip:504@ats01.kz.sipuni.com')
  end

  it 'rejects a later claim after first-answer-wins selected another operator' do
    described_class.new(account: account, user: winner_user, call_ref: call_session.external_call_ref).perform

    expect do
      described_class.new(account: account, user: other_user, call_ref: call_session.external_call_ref).perform
    end.to raise_error(Telephony::Error) { |error|
      expect(error.code).to eq('CALL_ALREADY_CLAIMED')
      expect(error.status).to eq(:conflict)
      expect(error.details[:agent_binding_id]).to eq(winner_binding.id)
      expect(error.details[:user_id]).to eq(winner_user.id)
      expect(error.details[:user_name]).to eq(winner_user.name)
    }

    expect(call_session.reload.agent_binding_id).to eq(winner_binding.id)
  end

  it 'rejects users outside the routed operator candidate pool' do
    create(:inbox_member, inbox: inbox, user: outsider_user)
    create(
      :telephony_agent_binding,
      :registered,
      account: account,
      user: outsider_user,
      agent_ref: 'agent-1003',
      agent_aor: 'sip:1003@voice.example'
    )

    expect do
      described_class.new(account: account, user: outsider_user, call_ref: call_session.external_call_ref).perform
    end.to raise_error(Telephony::Error) { |error|
      expect(error.code).to eq('OPERATOR_NOT_CANDIDATE')
      expect(error.status).to eq(:forbidden)
    }

    expect(call_session.reload.agent_binding_id).to be_nil
  end

  it 'rejects terminal calls' do
    call_session.update!(status: 'completed')

    expect do
      described_class.new(account: account, user: winner_user, call_ref: call_session.external_call_ref).perform
    end.to raise_error(Telephony::Error) { |error|
      expect(error.code).to eq('CALL_NOT_CLAIMABLE')
      expect(error.status).to eq(:conflict)
    }
  end
end
