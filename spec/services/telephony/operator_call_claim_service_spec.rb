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

  def mark_browser_profile_registered!(profile)
    profile.ensure_registration_config_version!
    profile.update_browser_registration!(
      registered: true,
      registration_context: {
        sip_profile_id: profile.id,
        account_id: profile.account_id,
        inbox_id: profile.inbox_id,
        internal_extension: profile.internal_extension,
        sip_username: profile.sip_username,
        sip_host: profile.sip_host,
        agent_aor: profile.agent_aor,
        registration_config_version: profile.registration_config_version,
        session_key: "sip_profile:#{profile.id}"
      }
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

  it 'broadcasts a claimed realtime event to every routed operator candidate' do
    broadcasts = []
    allow(ActionCable.server).to receive(:broadcast) do |token, event|
      broadcasts << [token, event]
    end

    described_class.new(account: account, user: winner_user, call_ref: call_session.external_call_ref).perform

    expect(broadcasts.map(&:first)).to contain_exactly(winner_user.pubsub_token, other_user.pubsub_token)
    expect(broadcasts.map(&:last)).to all(
      include(
        event: 'voice_call.claimed',
        data: include(
          account_id: account.id,
          call_sid: call_session.external_call_ref,
          related_call_sids: include(call_session.external_call_ref),
          claimed_by_user_id: winner_user.id
        )
      )
    )
  end

  it 'includes the communication thread in the claim response and realtime event' do
    account.enable_features!('communication_threads')
    communication_thread = call_session.conversation.refresh_communication_thread!
    broadcasts = []
    allow(ActionCable.server).to receive(:broadcast) do |_token, event|
      broadcasts << event
    end

    payload = described_class.new(account: account, user: winner_user, call_ref: call_session.external_call_ref).perform

    expect(payload[:communication_thread_id]).to eq(communication_thread.display_id)
    expect(broadcasts).to include(
      include(
        event: 'voice_call.claimed',
        data: include(
          communication_thread_id: communication_thread.display_id,
          communicationThreadId: communication_thread.display_id
        )
      )
    )
  end

  it 'does not mark another native SIP call with a different logical key as related by conversation fallback' do
    call_session.update!(
      from_number: '+77011110101',
      to_number: '+77022220202',
      metadata: {
        'metadata' => route_metadata.merge(
          'logical_call_key' => 'native-sip-inbound:first-real-call',
          'call_group_key' => 'native-sip-inbound:first-real-call'
        )
      }
    )
    unrelated_call = create(
      :telephony_call_session,
      account: account,
      conversation: call_session.conversation,
      contact: call_session.contact,
      inbox: call_session.inbox,
      number_binding: call_session.number_binding,
      provider: call_session.provider,
      direction: call_session.direction,
      status: 'ringing',
      from_number: call_session.from_number,
      to_number: call_session.to_number,
      metadata: {
        'metadata' => route_metadata.merge(
          'logical_call_key' => 'native-sip-inbound:second-real-call',
          'call_group_key' => 'native-sip-inbound:second-real-call'
        )
      }
    )

    broadcasts = []
    allow(ActionCable.server).to receive(:broadcast) do |_token, event|
      broadcasts << event
    end

    described_class.new(account: account, user: winner_user, call_ref: call_session.external_call_ref).perform

    related_call_sids = broadcasts.filter_map { |event| event.dig(:data, :related_call_sids) }.flatten.uniq
    expect(related_call_sids).to include(call_session.external_call_ref)
    expect(related_call_sids).not_to include(unrelated_call.external_call_ref)
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
          'operator_candidate_agent_refs' => [profile.agent_ref],
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
      agent_ref: profile.agent_ref,
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

  it 'keeps provider-owned SIP claims connecting until the browser Janus leg answers the call' do
    profile = create(
      :telephony_sip_profile,
      account: account,
      inbox: inbox,
      user: winner_user,
      internal_extension: '9098',
      availability_mode: 'browser_webphone',
      status: 'active',
      agent_ref: '9098',
      agent_aor: 'sip:9098@10.77.0.2',
      metadata: {
        registration_state: 'registered',
        presence: 'online',
        last_presence_event_at: Time.current.iso8601
      }
    )
    mark_browser_profile_registered!(profile)
    call_session.update!(
      provider: 'asterisk_analog',
      metadata: {
        'metadata' => {
          'route_action' => 'operator',
          'operator_pool' => true,
          'operator_candidate_sip_profile_ids' => [profile.id],
          'operator_candidate_user_ids' => [winner_user.id],
          'operator_candidate_agent_refs' => [profile.agent_ref],
          'operator_candidate_agent_aors' => [profile.agent_aor],
          'operator_candidate_sources' => ['sip_profile']
        }
      }
    )

    payload = described_class.new(account: account, user: winner_user,
                                  call_ref: call_session.external_call_ref).perform

    expect(payload).to include(
      claimed: true,
      status: 'connecting',
      sip_profile_id: profile.id,
      agent_ref: profile.agent_ref,
      agent_aor: profile.agent_aor
    )

    call_session.reload
    expect(call_session.status).to eq('connecting')
    expect(call_session.answered_at).to be_nil
    expect(call_session.metadata.dig('operator_claim', 'sip_profile_id')).to eq(profile.id)
  end

  it 'claims a Sipuni internal gateway target route when explicit candidate arrays are absent' do
    profile = create(
      :telephony_sip_profile,
      account: account,
      inbox: inbox,
      user: winner_user,
      internal_extension: '504',
      availability_mode: 'browser_webphone',
      status: 'active',
      agent_ref: 'profile-local-504',
      fonoster_agent_ref: 'fonoster-profile-504',
      agent_aor: 'sip:504@operator.cloud.vconsult.kz',
      metadata: {
        registration_state: 'registered',
        presence: 'online',
        last_presence_event_at: Time.current.iso8601
      }
    )
    mark_browser_profile_registered!(profile)
    call_session.update!(
      provider: 'sipuni',
      metadata: {
        'metadata' => {
          'source' => 'sipuni_internal_asterisk_gateway',
          'routeMode' => 'internal_asterisk_gateway',
          'target_extension' => '504',
          'onelink_user_id' => winner_user.id,
          'telephony_sip_profile_id' => profile.id,
          'target_operator_agent_aor' => 'sip:504@operator.cloud.vconsult.kz'
        }
      }
    )

    payload = described_class.new(account: account, user: winner_user, call_ref: call_session.external_call_ref).perform

    expect(payload).to include(
      claimed: true,
      sip_profile_id: profile.id,
      agent_ref: 'profile-local-504',
      agent_aor: 'sip:504@operator.cloud.vconsult.kz',
      user_id: winner_user.id
    )
    expect(call_session.reload.metadata.dig('operator_claim', 'sip_profile_id')).to eq(profile.id)
  end

  it 'rejects Sipuni claims before the internal operator leg is received' do
    provider_connection = create(
      :telephony_provider_connection,
      account: account,
      provider_kind: 'sipuni',
      host: 'ats01.kz.sipuni.com',
      username: '015856'
    )
    voice_channel = create(
      :channel_voice,
      account: account,
      provider: 'sipuni',
      phone_number: '+77070001001',
      provider_config: {
        provider_kind: 'sipuni',
        provider_connection_id: provider_connection.id,
        number_ref: 'sipuni-claim-test-line',
        routing_mode: 'operator'
      }
    )
    voice_inbox = voice_channel.inbox
    create(:inbox_member, inbox: voice_inbox, user: winner_user)
    profile = create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: winner_user,
      provider_connection: provider_connection,
      internal_extension: '505',
      availability_mode: 'browser_webphone',
      status: 'active',
      agent_ref: 'profile-local-505',
      fonoster_agent_ref: nil,
      agent_aor: 'sip:015856100021@ats01.kz.sipuni.com',
      last_synced_at: Time.current,
      metadata: {
        registration_state: 'registered',
        presence: 'online',
        last_presence_event_at: Time.current.iso8601
      }
    )
    call_session.update!(
      provider: 'sipuni',
      inbox: voice_inbox,
      metadata: {
        'metadata' => {
          'route_action' => 'operator',
          'sipuni_operator_leg' => false,
          'sipuni_leg_kind' => 'external',
          'operator_candidate_sip_profile_ids' => [profile.id],
          'operator_candidate_user_ids' => [winner_user.id],
          'operator_candidate_agent_refs' => [profile.agent_ref],
          'operator_candidate_agent_aors' => [profile.agent_aor],
          'operator_candidate_sources' => ['sip_profile']
        }
      }
    )

    expect do
      described_class.new(account: account, user: winner_user, call_ref: call_session.external_call_ref).perform
    end.to raise_error(Telephony::Error) { |error|
      expect(error.code).to eq('OPERATOR_NOT_CANDIDATE')
      expect(error.details[:reason]).to eq('sipuni_operator_leg_not_ready')
    }
    expect(call_session.reload.metadata['operator_claim']).to be_blank
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
