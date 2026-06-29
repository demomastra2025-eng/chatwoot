require 'rails_helper'
require 'tempfile'

RSpec.describe 'Telephony Bridge Routes', type: :request do
  let(:account) { create(:account) }
  let(:voice_channel) { create(:channel_voice, :fonoster, account: account, phone_number: voice_phone_number) }
  let(:voice_phone_number) { "+1555#{SecureRandom.random_number(10**8).to_s.rjust(8, '0')}" }
  let(:voice_inbox) { voice_channel.inbox }
  let(:number_binding) { voice_inbox.telephony_number_binding }
  let(:path) { '/internal/voice/inbound/route' }

  before do
    account.enable_features!('channel_voice')
    Telephony::NumberBinding.sync_from_voice_channel!(voice_channel)
  end

  it 'returns an operator route when the configured operator is available' do
    agent_binding = create(
      :telephony_agent_binding,
      :registered,
      account: account,
      agent_aor: 'sip:1001@example.test',
      enabled: true
    )
    number_binding.routing_policy.update!(
      mode: 'operator',
      operator_agent_ref: agent_binding.agent_ref,
      operator_agent_aor: agent_binding.agent_aor,
      fallback_mode: 'app'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-1',
             ingress_number: voice_channel.phone_number,
             caller_number: '+15559999999'
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'operator',
      'agent_aor' => 'sip:1001@example.test',
      'reason' => 'operator_route',
      'number_ref' => number_binding.number_ref,
      'inbox_id' => voice_inbox.id,
      'account_id' => account.id
    )
    expect(response.parsed_body['recording']).to include(
      'enabled' => true,
      'source' => 'onelink_runtime',
      'storage_provider' => 'onelink_storage'
    )
    expect(response.parsed_body).not_to have_key('fallback_mode')
    expect(response.parsed_body).not_to have_key('fallback_app_ref')
  end

  it 'does not route stale browser webphone SIP profiles before browser registration' do
    agent = create(:user, account: account, role: :agent)
    create(:inbox_member, inbox: voice_inbox, user: agent)
    create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: agent,
      availability_mode: 'browser_webphone',
      status: 'active',
      internal_extension: '504',
      agent_ref: 'profile-stale-browser-504',
      fonoster_agent_ref: 'fonoster-profile-stale-browser-504',
      agent_aor: 'sip:504@operator.cloud.vconsult.kz'
    )
    number_binding.routing_policy.update!(
      mode: 'operator',
      fallback_mode: 'reject'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-stale-browser-webphone',
             ingress_number: voice_channel.phone_number,
             caller_number: '+155****9988'
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'reject',
      'reason' => 'operator_unavailable'
    )
    expect(response.parsed_body).not_to have_key('agent_aor')
  end

  it 'routes provider-managed Sipuni SIP profiles without browser registration' do
    agent = create(:user, account: account, role: :agent)
    create(:inbox_member, inbox: voice_inbox, user: agent)
    number_binding.update!(
      number_ref: 'sipuni-internal-asterisk-provider-managed',
      metadata: { provider_kind: 'sipuni', source: 'sipuni_internal_asterisk_gateway' }
    )
    create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: agent,
      availability_mode: 'external_extension',
      status: 'active',
      internal_extension: '501',
      agent_ref: 'profile-sipuni-provider-501',
      fonoster_agent_ref: 'fonoster-profile-sipuni-provider-501',
      agent_aor: 'sip:501@ats01.kz.sipuni.com'
    )
    number_binding.routing_policy.update!(
      mode: 'operator',
      settings: { 'operator_distribution_mode' => Telephony::RoutingPolicy::OPERATOR_DISTRIBUTION_BROADCAST },
      fallback_mode: 'reject'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-sipuni-provider-extension',
             ingress_number: voice_channel.phone_number,
             caller_number: '+155****5001'
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'operator',
      'agent_aor' => 'sip:501@ats01.kz.sipuni.com',
      'reason' => 'operator_route',
      'number_ref' => number_binding.number_ref
    )
    expect(response.parsed_body.dig('operator_candidates', 0)).to include(
      'source' => 'sip_profile',
      'internal_extension' => '501',
      'availability_mode' => 'external_extension'
    )
  end

  it 'resolves tel URL target numbers before routing inbound calls' do
    agent_binding = create(
      :telephony_agent_binding,
      :registered,
      account: account,
      agent_aor: 'sip:1001@example.test',
      enabled: true
    )
    number_binding.routing_policy.update!(
      mode: 'operator',
      operator_agent_ref: agent_binding.agent_ref,
      operator_agent_aor: agent_binding.agent_aor,
      fallback_mode: 'reject'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-tel-url-target',
             to: "tel:#{voice_channel.phone_number}",
             caller_number: '+15559999997',
             diagnostic: true
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'operator',
      'agent_aor' => 'sip:1001@example.test',
      'reason' => 'operator_route',
      'number_ref' => number_binding.number_ref,
      'inbox_id' => voice_inbox.id,
      'account_id' => account.id
    )
  end

  it 'rejects a stale legacy operator instead of routing through the removed legacy fallback' do
    agent_binding = create(
      :telephony_agent_binding,
      account: account,
      agent_aor: 'sip:1001@example.test',
      enabled: true,
      last_synced_at: 15.minutes.ago,
      metadata: {
        registration_state: 'registered',
        presence: 'online',
        last_presence_source: 'browser_webphone',
        last_presence_event_at: 15.minutes.ago.iso8601
      }
    )
    number_binding.routing_policy.update!(
      mode: 'operator',
      operator_agent_ref: agent_binding.agent_ref,
      operator_agent_aor: agent_binding.agent_aor,
      fallback_mode: 'reject'
    )
    number_binding.update!(
      number_ref: 'sipuni-internal-asterisk-056124100014',
      metadata: { source: 'sipuni_internal_asterisk_gateway' }
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-stale-legacy-operator',
             ingress_number: voice_channel.phone_number,
             caller_number: '+15559999998'
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'reject',
      'reason' => 'operator_unavailable'
    )
    expect(response.parsed_body).not_to have_key('agent_aor')
  end

  it 'uses bridge account and inbox metadata when number_ref exists in multiple accounts' do
    other_account = create(:account)
    other_account.enable_features!('channel_voice')
    other_channel = create(
      :channel_voice,
      :fonoster,
      account: other_account,
      phone_number: '+15550002222'
    )
    other_channel.update!(
      provider_config: other_channel.provider_config.merge(
        number_ref: number_binding.number_ref,
        operator_agent_aor: 'sip:2002@example.test'
      )
    )
    other_binding = Telephony::NumberBinding.sync_from_voice_channel!(other_channel)
    other_agent_binding = create(
      :telephony_agent_binding,
      :registered,
      account: other_account,
      agent_aor: 'sip:2002@example.test',
      enabled: true
    )
    other_binding.routing_policy.update!(
      mode: 'operator',
      operator_agent_ref: other_agent_binding.agent_ref,
      operator_agent_aor: other_agent_binding.agent_aor,
      fallback_mode: 'reject'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-duplicate-ref',
             number_ref: number_binding.number_ref,
             ingress_number: other_channel.phone_number,
             caller_number: '+15559999998',
             metadata: {
               onelink_account_id: other_account.id,
               chatwoot_inbox_id: other_channel.inbox.id
             }
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'operator',
      'agent_aor' => 'sip:2002@example.test',
      'reason' => 'operator_route',
      'number_ref' => number_binding.number_ref,
      'inbox_id' => other_channel.inbox.id,
      'account_id' => other_account.id
    )
  end

  it 'broadcasts a lightweight native voice incoming call event to operator candidates' do
    agent = create(:user, account: account, role: :agent)
    contact = create(:contact, account: account, phone_number: '+15559999999')
    contact_inbox = create(:contact_inbox, contact: contact, inbox: voice_inbox, source_id: '+15559999999')
    conversation = create(
      :conversation,
      account: account,
      inbox: voice_inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      display_id: 627,
      status: :open
    )
    agent_binding = create(
      :telephony_agent_binding,
      :registered,
      account: account,
      user: agent,
      agent_aor: 'sip:1001@example.test',
      enabled: true
    )
    number_binding.routing_policy.update!(
      mode: 'operator',
      operator_agent_ref: agent_binding.agent_ref,
      operator_agent_aor: agent_binding.agent_aor,
      fallback_mode: 'reject'
    )

    allow(ActionCable.server).to receive(:broadcast)

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      expect do
        post path,
             params: {
               call_ref: 'fast-inbound-route',
               ingress_number: voice_channel.phone_number,
               caller_number: '+15559999999'
             },
             headers: { 'X-Bridge-Secret' => 'bridge-secret' },
             as: :json
      end.to have_enqueued_job(Telephony::InboundRouteLifecycleJob).on_queue('telephony_realtime')
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('action' => 'operator')

    call_session = account.telephony_call_sessions.find_by!(
      external_call_ref: 'fast-inbound-route'
    )
    expect(call_session).to have_attributes(
      status: 'ringing',
      direction: 'inbound',
      inbox_id: voice_inbox.id,
      number_binding_id: number_binding.id,
      conversation_id: conversation.id,
      contact_id: contact.id,
      from_number: '+15559999999',
      to_number: voice_channel.phone_number
    )
    expect(call_session.metadata.dig('metadata', 'route_action')).to eq(
      'operator'
    )
    expect(call_session.metadata.dig('metadata', 'logical_call_key')).to match(
      /\Afonoster-inbound:[a-f0-9]{32}\z/
    )
    expect(
      call_session.metadata.dig('metadata', 'operator_candidate_user_ids')
    ).to include(agent.id)
    expect(call_session.metadata.dig('fast_incoming_broadcast', 'event')).to eq(
      'voice_call.incoming'
    )

    expect(ActionCable.server).to have_received(:broadcast).with(
      agent.pubsub_token,
      event: 'voice_call.incoming',
      data: include(
        account_id: account.id,
        inbox_id: voice_inbox.id,
        provider: 'fonoster',
        call_sid: 'fast-inbound-route',
        logical_call_key: call_session.metadata.dig('metadata', 'logical_call_key'),
        logicalCallKey: call_session.metadata.dig('metadata', 'logical_call_key'),
        call_direction: 'inbound',
        conversation_id: conversation.display_id,
        from_number: '+15559999999',
        to_number: voice_channel.phone_number,
        caller: include(id: contact.id, phone_number: '+15559999999')
      )
    )

    claim = Telephony::OperatorCallClaimService.new(
      account: account,
      user: agent,
      call_ref: 'fast-inbound-route'
    ).perform
    expect(claim).to include(claimed: true, call_ref: 'fast-inbound-route')
  end

  it 'uses collision-resistant logical keys and shared bridge refs for inbound route branches' do
    agent_binding = create(
      :telephony_agent_binding,
      :registered,
      account: account,
      agent_aor: 'sip:1001@example.test',
      enabled: true
    )
    number_binding.routing_policy.update!(
      mode: 'operator',
      operator_agent_ref: agent_binding.agent_ref,
      operator_agent_aor: agent_binding.agent_aor,
      fallback_mode: 'reject'
    )

    keys = {}
    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      travel_to Time.zone.parse('2026-06-18 10:00:30 UTC') do
        [
          ['fallback-inbound-one', {}],
          ['fallback-inbound-two', {}],
          ['fallback-inbound-later', { travel: 25.seconds }],
          ['branch-inbound-one', { bridge_call_ref: 'bridge-parent-inbound' }],
          ['branch-inbound-two', { bridge_call_ref: 'bridge-parent-inbound' }]
        ].each do |call_ref, extra_params|
          travel extra_params.delete(:travel) if extra_params[:travel]

          post path,
               params: {
                 call_ref: call_ref,
                 ingress_number: voice_channel.phone_number,
                 caller_number: '+15556667777'
               }.merge(extra_params),
               headers: { 'X-Bridge-Secret' => 'bridge-secret' },
               as: :json

          expect(response).to have_http_status(:ok)
          keys[call_ref] = account.telephony_call_sessions.find_by!(
            external_call_ref: call_ref
          ).metadata.dig('metadata', 'logical_call_key')
        end
      end
    end

    expect(keys['fallback-inbound-one']).to match(/\Afonoster-inbound:[a-f0-9]{32}\z/)
    expect(keys['fallback-inbound-two']).to match(/\Afonoster-inbound:[a-f0-9]{32}\z/)
    expect(keys['fallback-inbound-two']).to eq(keys['fallback-inbound-one'])
    expect(keys['fallback-inbound-later']).to match(/\Afonoster-inbound:[a-f0-9]{32}\z/)
    expect(keys['fallback-inbound-later']).not_to eq(keys['fallback-inbound-one'])
    expect(keys['branch-inbound-one']).to eq(keys['branch-inbound-two'])
    expect(
      account.telephony_call_sessions.find_by!(
        external_call_ref: 'fallback-inbound-one'
      ).metadata.dig('metadata', 'logical_call_group_ref')
    ).to eq('fallback-inbound-one')
    expect(
      account.telephony_call_sessions.find_by!(
        external_call_ref: 'fallback-inbound-two'
      ).metadata.dig('metadata', 'logical_call_group_ref')
    ).to eq('fallback-inbound-one')
    expect(
      account.telephony_call_sessions.find_by!(
        external_call_ref: 'fallback-inbound-two'
      ).metadata.dig('metadata', 'logical_call_group_ref')
    ).to eq(
      account.telephony_call_sessions.find_by!(
        external_call_ref: 'fallback-inbound-one'
      ).metadata.dig('metadata', 'logical_call_group_ref')
    )
    expect(
      account.telephony_call_sessions.find_by!(
        external_call_ref: 'fallback-inbound-later'
      ).metadata.dig('metadata', 'logical_call_group_ref')
    ).not_to eq(
      account.telephony_call_sessions.find_by!(
        external_call_ref: 'fallback-inbound-one'
      ).metadata.dig('metadata', 'logical_call_group_ref')
    )
    expect(
      account.telephony_call_sessions.find_by!(
        external_call_ref: 'branch-inbound-one'
      ).metadata.dig('metadata', 'logical_call_group_ref')
    ).to eq('bridge-parent-inbound')
  end

  it 'does not persist route lifecycle or voice-call bubble for diagnostic audit probes' do
    caller_number = '+15550001010'
    contact = create(:contact, account: account, phone_number: caller_number)
    contact_inbox = create(:contact_inbox, contact: contact, inbox: voice_inbox, source_id: caller_number)
    create(
      :conversation,
      account: account,
      inbox: voice_inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      status: :open
    )

    agent_binding = create(
      :telephony_agent_binding,
      :registered,
      account: account,
      agent_aor: 'sip:1001@example.test',
      enabled: true
    )
    number_binding.routing_policy.update!(
      mode: 'operator',
      operator_agent_ref: agent_binding.agent_ref,
      operator_agent_aor: agent_binding.agent_aor,
      fallback_mode: 'reject'
    )

    allow(ActionCable.server).to receive(:broadcast)

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      expect do
        post path,
             params: {
               call_ref: 'audit-call',
               ingress_number: voice_channel.phone_number,
               caller_number: caller_number,
               diagnostic: true
             },
             headers: { 'X-Bridge-Secret' => 'bridge-secret' },
             as: :json
      end.not_to change(Telephony::CallSession, :count)
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'operator',
      'reason' => 'operator_route'
    )
    expect(response.parsed_body).not_to have_key('bridge_call_ref')
    expect(response.parsed_body).not_to have_key('conversation_id')
    expect(response.parsed_body).not_to have_key('conversation_display_id')
    expect(response.parsed_body).not_to have_key('conversation_status')
    expect(ActionCable.server).not_to have_received(:broadcast)
    expect(Message.voice_calls.where(source_id: 'voice_call:audit-call')).not_to exist
  end

  it 'rejects operator-mode calls when the browser registration is stale' do
    agent_binding = create(
      :telephony_agent_binding,
      account: account,
      agent_aor: 'sip:1001@example.test',
      enabled: true,
      last_synced_at: 6.minutes.ago,
      metadata: {
        registration_state: 'registered',
        registered: true,
        last_presence_event_at: 6.minutes.ago.iso8601
      }
    )
    number_binding.routing_policy.update!(
      mode: 'operator',
      operator_agent_ref: agent_binding.agent_ref,
      operator_agent_aor: agent_binding.agent_aor,
      fallback_mode: 'reject'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-stale-browser-registration',
             ingress_number: voice_channel.phone_number,
             caller_number: '+155****0103'
           },
           headers: { 'X-Bridge-Secret' => 'bridge-secret' },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'reject',
      'reason' => 'operator_unavailable'
    )
    expect(response.parsed_body).not_to have_key('agent_aor')
  end

  it 'rejects operator-mode calls while browser registration is still flapping' do
    agent_binding = create(
      :telephony_agent_binding,
      account: account,
      agent_aor: 'sip:1001@example.test',
      enabled: true,
      last_synced_at: 20.seconds.ago,
      metadata: {
        registration_state: 'registered',
        registered: true,
        last_presence_event_at: 20.seconds.ago.iso8601,
        last_unregistered_event_at: 2.seconds.ago.iso8601
      }
    )
    number_binding.routing_policy.update!(
      mode: 'operator',
      operator_agent_ref: agent_binding.agent_ref,
      operator_agent_aor: agent_binding.agent_aor,
      fallback_mode: 'reject'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-flapping-browser-registration',
             ingress_number: voice_channel.phone_number,
             caller_number: '+155****0104'
           },
           headers: { 'X-Bridge-Secret' => 'bridge-secret' },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'reject',
      'reason' => 'operator_unavailable'
    )
    expect(response.parsed_body).not_to have_key('agent_aor')
  end

  it 'routes operator-mode calls after browser re-registers following a disconnect' do
    agent_binding = create(
      :telephony_agent_binding,
      account: account,
      agent_aor: 'sip:1001@example.test',
      enabled: true,
      last_synced_at: Time.current,
      metadata: {
        registration_state: 'registered',
        registered: true,
        last_presence_event_at: Time.current.iso8601,
        last_unregistered_event_at: 2.seconds.ago.iso8601
      }
    )
    number_binding.routing_policy.update!(
      mode: 'operator',
      operator_agent_ref: agent_binding.agent_ref,
      operator_agent_aor: agent_binding.agent_aor,
      fallback_mode: 'reject'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-after-browser-reregister',
             ingress_number: voice_channel.phone_number,
             caller_number: '+155****0105'
           },
           headers: { 'X-Bridge-Secret' => 'bridge-secret' },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'operator',
      'agent_aor' => agent_binding.agent_aor
    )
  end

  it 'returns a registered operator pool for inbox members and excludes offline or busy bindings' do
    primary_user = create(:user, account: account, role: :agent)
    secondary_user = create(:user, account: account, role: :agent)
    busy_user = create(:user, account: account, role: :agent)
    offline_user = create(:user, account: account, role: :agent)
    non_member_user = create(:user, account: account, role: :agent)
    [primary_user, secondary_user, busy_user, offline_user].each { |user| create(:inbox_member, inbox: voice_inbox, user: user) }

    primary_binding = create(
      :telephony_agent_binding,
      :registered,
      account: account,
      user: primary_user,
      agent_ref: 'fonoster-agent-primary',
      agent_aor: 'sip:1001@example.test'
    )
    create(
      :telephony_agent_binding,
      :registered,
      account: account,
      user: secondary_user,
      agent_ref: 'fonoster-agent-secondary',
      agent_aor: 'sip:1002@example.test'
    )
    busy_binding = create(
      :telephony_agent_binding,
      :registered,
      account: account,
      user: busy_user,
      agent_ref: 'fonoster-agent-busy',
      agent_aor: 'sip:1003@example.test'
    )
    create(
      :telephony_agent_binding,
      account: account,
      user: offline_user,
      agent_ref: 'fonoster-agent-offline',
      agent_aor: 'sip:1004@example.test'
    )
    create(
      :telephony_agent_binding,
      :registered,
      account: account,
      user: non_member_user,
      agent_ref: 'fonoster-agent-non-member',
      agent_aor: 'sip:1005@example.test'
    )
    create(:telephony_call_session, account: account, agent_binding: busy_binding, status: 'in_progress')

    number_binding.routing_policy.update!(
      mode: 'operator',
      operator_agent_ref: primary_binding.agent_ref,
      operator_agent_aor: primary_binding.agent_aor,
      fallback_mode: 'reject'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      perform_enqueued_jobs do
        post path,
             params: {
               call_ref: 'inbound-route-operator-pool',
               ingress_number: voice_channel.phone_number,
               caller_number: '+155****0100'
             },
             headers: { 'X-Bridge-Secret' => 'bridge-secret' },
             as: :json
      end
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'operator',
      'agent_aor' => 'sip:1001@example.test',
      'agent_aors' => contain_exactly('sip:1001@example.test', 'sip:1002@example.test'),
      'operator_pool' => true,
      'operator_pool_size' => 2
    )
    expect(response.parsed_body['operator_candidates']).to contain_exactly(
      include('agent_ref' => 'fonoster-agent-primary', 'agent_aor' => 'sip:1001@example.test', 'user_id' => primary_user.id),
      include('agent_ref' => 'fonoster-agent-secondary', 'agent_aor' => 'sip:1002@example.test', 'user_id' => secondary_user.id)
    )

    call_session = account.telephony_call_sessions.find_by!(external_call_ref: 'inbound-route-operator-pool')
    expect(call_session.metadata.dig('metadata', 'operator_candidate_user_ids')).to contain_exactly(primary_user.id, secondary_user.id)
    expect(call_session.metadata.dig('metadata', 'operator_candidate_agent_refs')).to contain_exactly(
      'fonoster-agent-primary',
      'fonoster-agent-secondary'
    )
  end

  it 'routes managed Virtual PBX operator calls to SIP profiles scoped to the inbox' do
    primary_user = create(:user, account: account, role: :agent)
    secondary_user = create(:user, account: account, role: :agent)
    create(:inbox_member, inbox: voice_inbox, user: primary_user)
    create(:inbox_member, inbox: voice_inbox, user: secondary_user)

    provider_connection = create(
      :telephony_provider_connection,
      account: account,
      host: 'ats01.kz.sipuni.com',
      fonoster_trunk_ref: 'trunk-sipuni-onelink-out'
    )
    primary_profile = create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: primary_user,
      provider_connection: provider_connection,
      internal_extension: '504',
      agent_ref: 'profile-530-primary-504',
      fonoster_agent_ref: 'fonoster-profile-primary-504',
      agent_aor: 'sip:504@ats01.kz.sipuni.com'
    )
    secondary_profile = create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: secondary_user,
      provider_connection: provider_connection,
      internal_extension: '505',
      agent_ref: 'profile-530-secondary-505',
      fonoster_agent_ref: 'fonoster-profile-secondary-505',
      agent_aor: 'sip:505@ats01.kz.sipuni.com'
    )
    create(
      :telephony_agent_binding,
      :registered,
      account: account,
      user: primary_user,
      agent_ref: 'legacy-account-binding-1001',
      agent_aor: 'sip:1001@operator.cloud.vconsult.kz'
    )
    other_inbox = create(:inbox, account: account)
    create(
      :telephony_sip_profile,
      account: account,
      inbox: other_inbox,
      user: primary_user,
      provider_connection: provider_connection,
      internal_extension: '777',
      agent_ref: 'profile-other-inbox-777',
      fonoster_agent_ref: 'fonoster-profile-other-inbox-777',
      agent_aor: 'sip:777@ats01.kz.sipuni.com'
    )

    number_binding.routing_policy.update!(
      mode: 'operator',
      operator_agent_aor: 'sip:operator@ats01.kz.sipuni.com',
      fallback_mode: 'reject'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-sip-profile-pool',
             ingress_number: voice_channel.phone_number,
             caller_number: '+15551230050'
           },
           headers: { 'X-Bridge-Secret' => 'bridge-secret' },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'operator',
      'agent_aor' => 'sip:504@ats01.kz.sipuni.com',
      'agent_aors' => contain_exactly('sip:504@ats01.kz.sipuni.com', 'sip:505@ats01.kz.sipuni.com'),
      'operator_pool' => true,
      'operator_pool_size' => 2
    )
    expect(response.parsed_body['agent_aors']).not_to include(
      'sip:1001@operator.cloud.vconsult.kz',
      'sip:777@ats01.kz.sipuni.com'
    )
    expect(response.parsed_body['operator_candidates']).to contain_exactly(
      include(
        'source' => 'sip_profile',
        'sip_profile_id' => primary_profile.id,
        'agent_ref' => 'fonoster-profile-primary-504',
        'agent_aor' => 'sip:504@ats01.kz.sipuni.com',
        'user_id' => primary_user.id,
        'internal_extension' => '504'
      ),
      include(
        'source' => 'sip_profile',
        'sip_profile_id' => secondary_profile.id,
        'agent_ref' => 'fonoster-profile-secondary-505',
        'agent_aor' => 'sip:505@ats01.kz.sipuni.com',
        'user_id' => secondary_user.id,
        'internal_extension' => '505'
      )
    )

    call_session = account.telephony_call_sessions.find_by!(external_call_ref: 'inbound-route-sip-profile-pool')
    expect(call_session.metadata.dig('metadata', 'operator_candidate_sip_profile_ids')).to contain_exactly(
      primary_profile.id,
      secondary_profile.id
    )
    expect(call_session.metadata.dig('metadata', 'operator_candidate_binding_ids')).to be_empty
  end

  it 'does not use hidden account bindings for managed inbox members without SIP profiles in broadcast mode' do
    profiled_user = create(:user, account: account, role: :agent)
    binding_user = create(:user, account: account, role: :agent)
    create(:inbox_member, inbox: voice_inbox, user: profiled_user)
    create(:inbox_member, inbox: voice_inbox, user: binding_user)
    number_binding.update!(managed_by: Telephony::NumberBinding::MANAGED_BY_ONELINK, ownership_status: 'local')

    stale_profile = create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: profiled_user,
      internal_extension: '504',
      availability_mode: 'browser_webphone',
      status: 'active',
      agent_ref: 'profile-stale-504',
      fonoster_agent_ref: 'fonoster-profile-stale-504',
      agent_aor: 'sip:504@operator.cloud.vconsult.kz',
      metadata: {
        registration_state: 'registered',
        presence: 'online',
        last_presence_source: 'browser_webphone',
        last_presence_event_at: 15.minutes.ago.iso8601
      }
    )
    create(
      :telephony_agent_binding,
      :registered,
      account: account,
      user: profiled_user,
      agent_ref: 'legacy-profiled-user-1001',
      agent_aor: 'sip:1001@operator.cloud.vconsult.kz'
    )
    create(
      :telephony_agent_binding,
      :registered,
      account: account,
      user: binding_user,
      agent_ref: 'legacy-binding-user-1002',
      agent_aor: 'sip:1002@operator.cloud.vconsult.kz'
    )

    number_binding.routing_policy.update!(
      mode: 'operator',
      operator_agent_aor: stale_profile.agent_aor,
      settings: { 'operator_distribution_mode' => 'broadcast' },
      fallback_mode: 'reject'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-broadcast-binding-fallback',
             ingress_number: voice_channel.phone_number,
             caller_number: '+15551230100',
             diagnostic: true
           },
           headers: { 'X-Bridge-Secret' => 'bridge-secret' },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'reject',
      'reason' => 'operator_unavailable',
      'operator_distribution_mode' => 'broadcast'
    )
    expect(response.parsed_body).not_to have_key('agent_aor')
    expect(response.parsed_body).not_to have_key('operator_candidates')
  end

  it 'routes Sipuni target metadata to the matching managed SIP profile before the configured operator' do
    primary_user = create(:user, account: account, role: :agent)
    secondary_user = create(:user, account: account, role: :agent)
    create(:inbox_member, inbox: voice_inbox, user: primary_user)
    create(:inbox_member, inbox: voice_inbox, user: secondary_user)

    provider_connection = create(:telephony_provider_connection, account: account, host: 'ats01.kz.sipuni.com')
    primary_profile = create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: primary_user,
      provider_connection: provider_connection,
      internal_extension: '504',
      agent_ref: 'profile-target-primary-504',
      fonoster_agent_ref: 'fonoster-target-primary-504',
      agent_aor: 'sip:504@operator.cloud.vconsult.kz'
    )
    secondary_profile = create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: secondary_user,
      provider_connection: provider_connection,
      internal_extension: '505',
      agent_ref: 'profile-target-secondary-505',
      fonoster_agent_ref: 'fonoster-target-secondary-505',
      agent_aor: 'sip:505@operator.cloud.vconsult.kz'
    )

    number_binding.routing_policy.update!(
      mode: 'operator',
      operator_agent_aor: primary_profile.agent_aor,
      settings: { 'operator_distribution_mode' => 'targeted' },
      fallback_mode: 'reject'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-target-extension-505',
             ingress_number: voice_channel.phone_number,
             caller_number: '+155500005051',
             metadata: {
               target_extension: '505',
               operator_agent_aor: secondary_profile.agent_aor
             }
           },
           headers: { 'X-Bridge-Secret' => 'bridge-secret' },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'operator',
      'reason' => 'operator_route',
      'agent_aor' => secondary_profile.agent_aor,
      'agent_ref' => secondary_profile.fonoster_agent_ref,
      'agent_aors' => [secondary_profile.agent_aor],
      'operator_pool' => false,
      'operator_pool_size' => 1
    )
    expect(response.parsed_body['operator_candidates']).to contain_exactly(
      include(
        'source' => 'sip_profile',
        'sip_profile_id' => secondary_profile.id,
        'internal_extension' => '505',
        'agent_aor' => secondary_profile.agent_aor,
        'user_id' => secondary_user.id
      )
    )

    call_session = account.telephony_call_sessions.find_by!(external_call_ref: 'inbound-route-target-extension-505')
    expect(call_session.metadata.dig('metadata', 'target_extension')).to eq('505')
    expect(call_session.metadata.dig('metadata', 'target_operator_agent_aor')).to eq(secondary_profile.agent_aor)
    expect(call_session.metadata.dig('metadata', 'operator_candidate_sip_profile_ids')).to contain_exactly(secondary_profile.id)
  end

  it 'ignores Sipuni target metadata in broadcast operator distribution mode' do
    primary_user = create(:user, account: account, role: :agent)
    secondary_user = create(:user, account: account, role: :agent)
    create(:inbox_member, inbox: voice_inbox, user: primary_user)
    create(:inbox_member, inbox: voice_inbox, user: secondary_user)

    primary_profile = create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: primary_user,
      internal_extension: '504',
      agent_aor: 'sip:504@operator.cloud.vconsult.kz'
    )
    secondary_profile = create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: secondary_user,
      internal_extension: '505',
      agent_aor: 'sip:505@operator.cloud.vconsult.kz'
    )

    number_binding.routing_policy.update!(
      mode: 'operator',
      settings: { 'operator_distribution_mode' => 'broadcast' },
      fallback_mode: 'reject'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-broadcast-ignores-target-extension',
             ingress_number: voice_channel.phone_number,
             caller_number: '+155500005050',
             diagnostic: true,
             metadata: {
               target_extension: '505',
               operator_agent_aor: secondary_profile.agent_aor
             }
           },
           headers: { 'X-Bridge-Secret' => 'bridge-secret' },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'operator',
      'operator_distribution_mode' => 'broadcast',
      'operator_pool' => true,
      'operator_pool_size' => 2
    )
    expect(response.parsed_body['agent_aors']).to contain_exactly(
      primary_profile.agent_aor,
      secondary_profile.agent_aor
    )
  end

  it 'rejects duplicate fresh targeted branches in broadcast operator distribution mode' do
    agent = create(:user, account: account, role: :agent)
    create(:inbox_member, inbox: voice_inbox, user: agent)
    create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: agent,
      internal_extension: '504',
      agent_aor: 'sip:504@operator.cloud.vconsult.kz'
    )
    number_binding.routing_policy.update!(
      mode: 'operator',
      settings: { 'operator_distribution_mode' => 'broadcast' },
      fallback_mode: 'reject'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-broadcast-primary',
             ingress_number: voice_channel.phone_number,
             caller_number: '+155500005060'
           },
           headers: { 'X-Bridge-Secret' => 'bridge-secret' },
           as: :json
      expect(response.parsed_body).to include('action' => 'operator')

      post path,
           params: {
             call_ref: 'inbound-route-broadcast-duplicate',
             ingress_number: voice_channel.phone_number,
             caller_number: '+155500005060',
             metadata: { target_extension: '504' }
           },
           headers: { 'X-Bridge-Secret' => 'bridge-secret' },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'reject',
      'reason' => 'duplicate_broadcast_branch'
    )
  end

  it 'rejects a Sipuni target extension that is not assigned in the inbox instead of falling back to another operator' do
    primary_user = create(:user, account: account, role: :agent)
    other_user = create(:user, account: account, role: :agent)
    create(:inbox_member, inbox: voice_inbox, user: primary_user)

    provider_connection = create(:telephony_provider_connection, account: account, host: 'ats01.kz.sipuni.com')
    primary_profile = create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: primary_user,
      provider_connection: provider_connection,
      internal_extension: '504',
      agent_aor: 'sip:504@operator.cloud.vconsult.kz'
    )
    other_inbox = create(:inbox, account: account)
    create(
      :telephony_sip_profile,
      account: account,
      inbox: other_inbox,
      user: other_user,
      provider_connection: provider_connection,
      internal_extension: '505',
      agent_aor: 'sip:505@operator.cloud.vconsult.kz'
    )

    number_binding.routing_policy.update!(
      mode: 'operator',
      operator_agent_aor: primary_profile.agent_aor,
      settings: { 'operator_distribution_mode' => 'targeted' },
      fallback_mode: 'reject'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-target-extension-missing',
             ingress_number: voice_channel.phone_number,
             caller_number: '+155500005052',
             diagnostic: true,
             metadata: { target_extension: '505' }
           },
           headers: { 'X-Bridge-Secret' => 'bridge-secret' },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'reject',
      'reason' => 'target_operator_not_found'
    )
    expect(response.parsed_body).not_to have_key('agent_aor')
  end

  it 'rejects an unavailable Sipuni target profile instead of falling back to another operator' do
    primary_user = create(:user, account: account, role: :agent)
    secondary_user = create(:user, account: account, role: :agent)
    create(:inbox_member, inbox: voice_inbox, user: primary_user)
    create(:inbox_member, inbox: voice_inbox, user: secondary_user)

    primary_profile = create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: primary_user,
      internal_extension: '504',
      agent_aor: 'sip:504@operator.cloud.vconsult.kz'
    )
    create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: secondary_user,
      availability_mode: 'browser_webphone',
      status: 'active',
      internal_extension: '505',
      agent_aor: 'sip:505@operator.cloud.vconsult.kz'
    )

    number_binding.routing_policy.update!(
      mode: 'operator',
      operator_agent_aor: primary_profile.agent_aor,
      settings: { 'operator_distribution_mode' => 'targeted' },
      fallback_mode: 'reject'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-target-extension-unavailable',
             ingress_number: voice_channel.phone_number,
             caller_number: '+155500005053',
             diagnostic: true,
             metadata: { target_extension: '505' }
           },
           headers: { 'X-Bridge-Secret' => 'bridge-secret' },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'reject',
      'reason' => 'target_operator_unavailable'
    )
    expect(response.parsed_body).not_to have_key('agent_aor')
  end

  it 'rejects a busy Sipuni target profile instead of falling back to another operator' do
    primary_user = create(:user, account: account, role: :agent)
    secondary_user = create(:user, account: account, role: :agent)
    create(:inbox_member, inbox: voice_inbox, user: primary_user)
    create(:inbox_member, inbox: voice_inbox, user: secondary_user)

    primary_profile = create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: primary_user,
      internal_extension: '504',
      agent_aor: 'sip:504@operator.cloud.vconsult.kz'
    )
    busy_profile = create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: secondary_user,
      internal_extension: '505',
      agent_aor: 'sip:505@operator.cloud.vconsult.kz'
    )
    create(
      :telephony_call_session,
      account: account,
      inbox: voice_inbox,
      number_binding: number_binding,
      external_call_ref: 'already-claimed-target-505-call',
      direction: 'inbound',
      status: 'connecting',
      from_number: '+155500000001',
      to_number: voice_channel.phone_number,
      metadata: {
        'operator_claim' => {
          'sip_profile_id' => busy_profile.id,
          'user_id' => secondary_user.id
        }
      }
    )

    number_binding.routing_policy.update!(
      mode: 'operator',
      operator_agent_aor: primary_profile.agent_aor,
      settings: { 'operator_distribution_mode' => 'targeted' },
      fallback_mode: 'reject'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-target-extension-busy',
             ingress_number: voice_channel.phone_number,
             caller_number: '+155500005054',
             diagnostic: true,
             metadata: { target_extension: '505' }
           },
           headers: { 'X-Bridge-Secret' => 'bridge-secret' },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'reject',
      'reason' => 'target_operator_busy'
    )
    expect(response.parsed_body).not_to have_key('agent_aor')
  end

  it 'excludes already claimed SIP profiles from the managed Virtual PBX operator pool' do
    primary_user = create(:user, account: account, role: :agent)
    secondary_user = create(:user, account: account, role: :agent)
    create(:inbox_member, inbox: voice_inbox, user: primary_user)
    create(:inbox_member, inbox: voice_inbox, user: secondary_user)

    provider_connection = create(
      :telephony_provider_connection,
      account: account,
      host: 'ats01.kz.sipuni.com',
      fonoster_trunk_ref: 'trunk-sipuni-onelink-out'
    )
    busy_profile = create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: primary_user,
      provider_connection: provider_connection,
      internal_extension: '504',
      agent_ref: 'profile-busy-504',
      fonoster_agent_ref: 'fonoster-profile-busy-504',
      agent_aor: 'sip:504@ats01.kz.sipuni.com'
    )
    available_profile = create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: secondary_user,
      provider_connection: provider_connection,
      internal_extension: '505',
      agent_ref: 'profile-available-505',
      fonoster_agent_ref: 'fonoster-profile-available-505',
      agent_aor: 'sip:505@ats01.kz.sipuni.com'
    )
    create(
      :telephony_call_session,
      account: account,
      inbox: voice_inbox,
      number_binding: number_binding,
      conversation: nil,
      contact: nil,
      external_call_ref: 'already-claimed-sip-profile-call',
      direction: 'inbound',
      status: 'connecting',
      from_number: '+15550000001',
      to_number: voice_channel.phone_number,
      metadata: {
        'operator_claim' => {
          'sip_profile_id' => busy_profile.id,
          'user_id' => primary_user.id
        }
      }
    )

    number_binding.routing_policy.update!(
      mode: 'operator',
      operator_agent_aor: 'sip:operator@ats01.kz.sipuni.com',
      fallback_mode: 'reject'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-sip-profile-busy-filter',
             ingress_number: voice_channel.phone_number,
             caller_number: '+15551230051'
           },
           headers: { 'X-Bridge-Secret' => 'bridge-secret' },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'operator',
      'agent_aor' => available_profile.agent_aor,
      'agent_aors' => [available_profile.agent_aor],
      'operator_pool_size' => 1
    )
    expect(response.parsed_body['agent_aors']).not_to include(busy_profile.agent_aor)
    expect(response.parsed_body['operator_candidates']).to contain_exactly(
      include(
        'source' => 'sip_profile',
        'sip_profile_id' => available_profile.id,
        'agent_ref' => available_profile.fonoster_agent_ref,
        'agent_aor' => available_profile.agent_aor,
        'user_id' => secondary_user.id,
        'internal_extension' => '505'
      )
    )
  end

  it 'rejects operator-mode calls when a SIP operator AOR has no registration binding' do
    number_binding.routing_policy.update!(
      mode: 'operator',
      operator_agent_aor: 'sip:unregistered@example.test',
      fallback_mode: 'app'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-no-operator-registration',
             ingress_number: voice_channel.phone_number,
             caller_number: '+155****0101'
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'reject',
      'reason' => 'operator_unavailable'
    )
    expect(response.parsed_body).not_to have_key('agent_aor')
    expect(response.parsed_body).not_to have_key('app_ref')
  end

  it 'does not fall back from operator mode to AI when the operator target is missing' do
    number_binding.routing_policy.assign_attributes(
      mode: 'operator',
      operator_agent_ref: nil,
      operator_agent_aor: nil,
      ai_enabled: true,
      ai_deployment_mode: 'onelink_managed',
      onelink_ai_app_ref: 'captain-ai-app-ref',
      fallback_mode: 'app'
    )
    number_binding.routing_policy.save!(validate: false)

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-no-operator-registration-ai-side',
             ingress_number: voice_channel.phone_number,
             caller_number: '+15555550102'
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'reject',
      'reason' => 'operator_unavailable'
    )
    expect(response.parsed_body).not_to have_key('app_ref')
  end

  it 'creates an idempotent native call lifecycle during route lookup' do
    number_binding.routing_policy.update!(
      mode: 'operator',
      operator_agent_aor: 'sip:1001@example.test',
      fallback_mode: 'reject'
    )

    route_request = lambda do
      post path,
           params: {
             call_ref: 'inbound-route-lifecycle',
             ingress_number: voice_channel.phone_number,
             caller_number: '+15551239998'
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      expect do
        perform_enqueued_jobs do
          2.times { route_request.call }
        end
      end.to change(Telephony::CallSession, :count).by(1)
                                                   .and change(Conversation, :count).by(1)
                                                                                    .and change(Message, :count).by(1)
    end

    expect(response).to have_http_status(:ok)
    call_session = account.telephony_call_sessions.find_by!(external_call_ref: 'inbound-route-lifecycle')
    expect(call_session).to have_attributes(
      status: 'ringing',
      direction: 'inbound',
      inbox_id: voice_inbox.id,
      number_binding_id: number_binding.id,
      from_number: '+15551239998',
      to_number: voice_channel.phone_number
    )
    expect(call_session.conversation).to be_present
    expect(call_session.conversation.identifier).to be_blank
    expect(call_session.conversation.additional_attributes['fonoster_call_ref']).to eq('inbound-route-lifecycle')
    expect(call_session.conversation.messages.where(content_type: 'voice_call').count).to eq(1)
    expect(call_session.conversation.messages.voice_calls.find_by!(source_id: 'voice_call:inbound-route-lifecycle')).to be_present
  end

  it 'normalizes trunk-prefix caller numbers in native route lifecycle records' do
    number_binding.routing_policy.update!(
      mode: 'reject',
      fallback_mode: 'reject'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      perform_enqueued_jobs do
        post path,
             params: {
               call_ref: 'inbound-route-kz-trunk-prefix',
               ingress_number: voice_channel.phone_number,
               caller_number: '87066318623'
             },
             headers: {
               'X-Bridge-Secret' => 'bridge-secret'
             },
             as: :json
      end
    end

    expect(response).to have_http_status(:ok)
    call_session = account.telephony_call_sessions.find_by!(external_call_ref: 'inbound-route-kz-trunk-prefix')
    expect(call_session.from_number).to eq('+77066318623')
    expect(call_session.conversation.contact.phone_number).to eq('+77066318623')
    expect(call_session.conversation.messages.voice_calls.first.content_attributes.dig('data', 'from_number')).to eq('+77066318623')
  end

  it 'rejects non-SIP operator targets instead of returning a non-executable operator route' do
    number_binding.routing_policy.update_columns(
      mode: 'operator',
      operator_agent_aor: 'operator1',
      fallback_mode: 'reject'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-destination',
             ingress_number: voice_channel.phone_number,
             caller_number: '+15551230001'
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'reject',
      'reason' => 'operator_unavailable'
    )
    expect(response.parsed_body).not_to have_key('agent_aor')
    expect(response.parsed_body).not_to have_key('destination')
  end

  it 'persists a voice-call timeline item for a rejected route on an existing conversation' do
    caller_number = '+15550000000'
    contact = create(:contact, account: account, phone_number: caller_number)
    contact_inbox = create(:contact_inbox, contact: contact, inbox: voice_inbox, source_id: caller_number)
    conversation = create(
      :conversation,
      account: account,
      inbox: voice_inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      status: :open
    )

    number_binding.routing_policy.update!(mode: 'operator', fallback_mode: 'reject')

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      expect do
        perform_enqueued_jobs do
          post path,
               params: {
                 call_ref: 'existing-conversation-rejected-route',
                 ingress_number: voice_channel.phone_number,
                 caller_number: caller_number
               },
               headers: {
                 'X-Bridge-Secret' => 'bridge-secret'
               },
               as: :json
        end
      end.to change(Message, :count).by(1)

      perform_enqueued_jobs(only: Telephony::InboundRouteLifecycleJob) do
        post '/internal/voice/inbound/event',
             params: {
               call_ref: 'existing-conversation-rejected-route',
               event: 'rejected',
               account_id: account.id,
               inbox_id: voice_inbox.id,
               number_ref: number_binding.number_ref,
               caller_number: caller_number,
               status: 'rejected',
               terminal: true
             },
             headers: {
               'X-Bridge-Secret' => 'bridge-secret'
             },
             as: :json
      end
    end

    expect(response).to have_http_status(:accepted)
    call_session = account.telephony_call_sessions.find_by!(external_call_ref: 'existing-conversation-rejected-route')
    expect(call_session.reload).to have_attributes(
      conversation_id: conversation.id,
      status: 'rejected'
    )
    voice_message = conversation.messages.voice_calls.find_by!(source_id: 'voice_call:existing-conversation-rejected-route')
    expect(voice_message.content_attributes.dig('data', 'status')).to eq('rejected')
    expect(voice_message.content_attributes.dig('data', 'call_sid')).to eq('existing-conversation-rejected-route')
  end

  it 'accepts bearer token authentication for inbound route lookups' do
    number_binding.routing_policy.update!(
      mode: 'reject',
      fallback_message: 'Rejected by bearer auth'
    )

    with_modified_env(TELEPHONY_BRIDGE_ACCESS_TOKEN: 'bridge-access-token') do
      post path,
           params: {
             call_ref: 'inbound-route-bearer',
             ingress_number: voice_channel.phone_number,
             caller_number: '+15551236666'
           },
           headers: {
             'Authorization' => 'Bearer bridge-access-token'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'reject',
      'reason' => 'reject_route',
      'message' => 'Rejected by bearer auth'
    )
  end

  it 'fails closed with an executable reject decision when routing raises after authentication' do
    allow(Telephony::InboundRoutingService).to receive(:new)
      .and_raise(Telephony::Error.new(code: 'ROUTE_LOOKUP_FAILED', message: 'Route lookup failed', status: :bad_gateway))

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-error',
             ingress_number: voice_channel.phone_number,
             caller_number: '+15551230002'
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'reject',
      'reason' => 'ROUTE_LOOKUP_FAILED',
      'message' => 'Route lookup failed'
    )
  end

  it 'rejects operator-mode calls when the operator is disabled instead of app fallback' do
    agent_binding = create(
      :telephony_agent_binding,
      account: account,
      agent_aor: 'sip:1002@example.test',
      enabled: false
    )
    number_binding.routing_policy.update!(
      mode: 'operator',
      operator_agent_ref: agent_binding.agent_ref,
      operator_agent_aor: agent_binding.agent_aor,
      fallback_mode: 'app'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             callRef: 'inbound-route-2',
             ingressNumber: voice_channel.phone_number,
             callerNumber: '+15551238888'
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'reject',
      'reason' => 'operator_unavailable'
    )
    expect(response.parsed_body).not_to have_key('app_ref')
  end

  it 'rejects operator-mode calls when the operator is disabled instead of AI fallback' do
    agent_binding = create(
      :telephony_agent_binding,
      account: account,
      agent_aor: 'sip:1007@example.test',
      enabled: false
    )
    number_binding.routing_policy.update!(
      mode: 'operator',
      operator_agent_ref: agent_binding.agent_ref,
      operator_agent_aor: agent_binding.agent_aor,
      ai_app_ref: 'ai-fallback-app-ref',
      fallback_mode: 'ai'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             callRef: 'inbound-route-ai-fallback',
             ingressNumber: voice_channel.phone_number,
             callerNumber: '+15551238889'
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'reject',
      'reason' => 'operator_unavailable'
    )
    expect(response.parsed_body).not_to have_key('app_ref')
  end

  it 'routes an existing pending voice conversation to AI when AI routing is enabled' do
    caller_number = '+15551230001'
    contact = create(:contact, account: account, phone_number: caller_number)
    contact_inbox = create(:contact_inbox, contact: contact, inbox: voice_inbox, source_id: caller_number)
    conversation = create(
      :conversation,
      account: account,
      inbox: voice_inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      status: :pending
    )
    create(
      :telephony_call_session,
      account: account,
      inbox: voice_inbox,
      number_binding: number_binding,
      conversation: conversation,
      external_call_ref: 'bridge-call-pending',
      status: 'in_progress'
    )

    number_binding.routing_policy.update!(
      mode: 'ai',
      ai_app_ref: 'ai-status-aware-app-ref',
      operator_agent_aor: 'sip:status-aware-operator@example.test',
      fallback_mode: 'operator'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-status-pending',
             ingress_number: voice_channel.phone_number,
             caller_number: caller_number
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'ai',
      'app_ref' => 'ai-status-aware-app-ref',
      'reason' => 'pending_conversation_ai_route',
      'bridge_call_ref' => 'bridge-call-pending'
    )
  end

  it 'keeps a recent terminal bridge call ref for the AI runtime leg correlation' do
    caller_number = '+15550000002'
    contact = create(:contact, account: account, phone_number: caller_number)
    contact_inbox = create(:contact_inbox, contact: contact, inbox: voice_inbox, source_id: caller_number)
    conversation = create(
      :conversation,
      account: account,
      inbox: voice_inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      status: :pending
    )
    create(
      :telephony_call_session,
      account: account,
      inbox: voice_inbox,
      number_binding: number_binding,
      conversation: conversation,
      external_call_ref: 'bridge-call-terminal-recent',
      status: 'cancelled',
      end_reason: 'voice_stream_ended_before_app_answer',
      created_at: 10.seconds.ago,
      updated_at: 9.seconds.ago
    )

    number_binding.routing_policy.update!(
      mode: 'ai',
      ai_app_ref: 'ai-status-aware-app-ref',
      operator_agent_aor: 'sip:status-aware-operator@example.test',
      fallback_mode: 'operator'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'runtime-app-leg-recent-terminal',
             ingress_number: voice_channel.phone_number,
             caller_number: caller_number,
             app_ref: 'ai-status-aware-app-ref'
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'app',
      'reason' => 'recursive_runtime_app_ref',
      'bridge_call_ref' => 'bridge-call-terminal-recent'
    )
  end

  it 'does not route a pending conversation to AI when the primary routing mode remains operator' do
    caller_number = '+15551230003'
    contact = create(:contact, account: account, phone_number: caller_number)
    contact_inbox = create(:contact_inbox, contact: contact, inbox: voice_inbox, source_id: caller_number)
    create(
      :conversation,
      account: account,
      inbox: voice_inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      status: :pending
    )

    number_binding.routing_policy.update!(
      mode: 'operator',
      operator_agent_aor: 'sip:status-aware-operator@example.test',
      ai_app_ref: 'ai-status-aware-app-ref',
      fallback_mode: 'ai'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-operator-primary-pending',
             ingress_number: voice_channel.phone_number,
             caller_number: caller_number
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'reject',
      'reason' => 'operator_unavailable'
    )
    expect(response.parsed_body).not_to have_key('app_ref')
  end

  it 'does not route pending conversations to AI when operator mode has AI enabled only as fallback' do
    caller_number = '+15550000004'
    contact = create(:contact, account: account, phone_number: caller_number)
    contact_inbox = create(:contact_inbox, contact: contact, inbox: voice_inbox, source_id: caller_number)
    create(
      :conversation,
      account: account,
      inbox: voice_inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      status: :pending
    )

    number_binding.routing_policy.update!(
      mode: 'operator',
      ai_enabled: true,
      ai_deployment_mode: 'onelink_managed',
      onelink_ai_app_ref: 'onelink-ai-status-aware-app-ref',
      operator_agent_aor: 'sip:status-aware-operator@example.test',
      fallback_mode: 'app'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-ai-enabled-operator-primary-pending',
             ingress_number: voice_channel.phone_number,
             caller_number: caller_number
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(number_binding.routing_policy.reload.ai_enabled).to be(true)
    expect(response.parsed_body).to include(
      'action' => 'reject',
      'reason' => 'operator_unavailable'
    )
    expect(response.parsed_body).not_to have_key('app_ref')
  end

  it 'routes an existing pending voice conversation to Captain AI using the managed app ref fallback' do
    caller_number = '+15550000005'
    contact = create(:contact, account: account, phone_number: caller_number)
    contact_inbox = create(:contact_inbox, contact: contact, inbox: voice_inbox, source_id: caller_number)
    assistant = create(:captain_assistant, account: account)
    conversation = create(
      :conversation,
      account: account,
      inbox: voice_inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      status: :pending
    )
    create(
      :telephony_call_session,
      account: account,
      inbox: voice_inbox,
      number_binding: number_binding,
      conversation: conversation,
      external_call_ref: 'bridge-call-captain-operator-pending',
      status: 'in_progress'
    )

    number_binding.routing_policy.update!(
      mode: 'operator',
      ai_enabled: true,
      ai_deployment_mode: 'onelink_managed',
      captain_assistant: assistant,
      operator_agent_aor: 'sip:status-aware-operator@example.test',
      fallback_mode: 'app'
    )

    with_modified_env(
      TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret',
      ONELINK_AI_VOICE_APP_REF: 'onelink-captain-ai-status-aware-app-ref'
    ) do
      post path,
           params: {
             call_ref: 'inbound-route-captain-linked-operator-primary-pending',
             ingress_number: voice_channel.phone_number,
             caller_number: caller_number
           },
           headers: { 'X-Bridge-Secret' => 'bridge-secret' },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(number_binding.routing_policy.reload.onelink_ai_app_ref).to be_nil
    expect(response.parsed_body).to include(
      'action' => 'ai',
      'app_ref' => 'onelink-captain-ai-status-aware-app-ref',
      'reason' => 'pending_conversation_ai_route',
      'bridge_call_ref' => 'bridge-call-captain-operator-pending'
    )
  end

  it 'keeps AI-mode calls on AI for every existing non-pending voice conversation status' do
    agent_binding = create(
      :telephony_agent_binding,
      :registered,
      account: account,
      agent_aor: 'sip:status-aware-operator@example.test',
      enabled: true
    )
    number_binding.routing_policy.update!(
      mode: 'ai',
      ai_app_ref: 'ai-status-aware-app-ref',
      operator_agent_ref: agent_binding.agent_ref,
      operator_agent_aor: agent_binding.agent_aor,
      fallback_mode: 'operator'
    )

    %w[open resolved snoozed].each_with_index do |status, index|
      caller_number = "+1555123001#{index}"
      contact = create(:contact, account: account, phone_number: caller_number)
      contact_inbox = create(:contact_inbox, contact: contact, inbox: voice_inbox, source_id: caller_number)
      create(
        :conversation,
        account: account,
        inbox: voice_inbox,
        contact: contact,
        contact_inbox: contact_inbox,
        status: status
      )

      with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
        post path,
             params: {
               call_ref: "inbound-route-status-#{status}",
               ingress_number: voice_channel.phone_number,
               caller_number: caller_number
             },
             headers: {
               'X-Bridge-Secret' => 'bridge-secret'
             },
             as: :json
      end

      aggregate_failures(status) do
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to include(
          'action' => 'ai',
          'app_ref' => 'ai-status-aware-app-ref',
          'reason' => 'ai_route'
        )
      end
    end
  end

  it 'routes AI calls to the OneLink-managed realtime voice app when that deployment mode is enabled' do
    number_binding.routing_policy.update!(
      mode: 'ai',
      ai_deployment_mode: 'onelink_managed',
      ai_app_ref: 'legacy-fonoster-ai-app',
      fonoster_ai_app_ref: 'legacy-fonoster-ai-app',
      onelink_ai_app_ref: 'onelink-ai-voice-app',
      fallback_mode: 'reject'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-onelink-ai',
             ingress_number: voice_channel.phone_number,
             caller_number: '+15557777777'
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'ai',
      'ai_mode' => 'onelink_managed',
      'app_ref' => 'onelink-ai-voice-app',
      'reason' => 'ai_route',
      'number_ref' => number_binding.number_ref
    )
  end

  it 'keeps direct OneLink AI runtime routes on the AI app instead of falling back to the legacy router app' do
    number_binding.update!(app_ref: 'legacy-router-app')
    number_binding.routing_policy.update!(
      mode: 'ai',
      ai_deployment_mode: 'onelink_managed',
      ai_app_ref: 'legacy-fonoster-ai-app',
      fonoster_ai_app_ref: 'legacy-fonoster-ai-app',
      onelink_ai_app_ref: 'direct-onelink-ai-app',
      fallback_mode: 'app'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-direct-ai-runtime',
             ingress_number: voice_channel.phone_number,
             caller_number: '+155****7779',
             app_ref: 'direct-onelink-ai-app'
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'ai',
      'ai_mode' => 'onelink_managed',
      'app_ref' => 'direct-onelink-ai-app',
      'reason' => 'ai_route'
    )
    expect(response.parsed_body['app_ref']).not_to eq('legacy-router-app')
  end

  it 'rejects recursive direct OneLink AI runtime legs while an active leg is already open' do
    caller_number = '+15558888880'
    contact = create(:contact, account: account, phone_number: caller_number)
    contact_inbox = create(:contact_inbox, contact: contact, inbox: voice_inbox, source_id: caller_number)
    conversation = create(
      :conversation,
      account: account,
      inbox: voice_inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      status: :pending
    )
    create(
      :telephony_call_session,
      account: account,
      inbox: voice_inbox,
      number_binding: number_binding,
      conversation: conversation,
      external_call_ref: 'active-direct-runtime-leg',
      status: 'ringing',
      created_at: 10.seconds.ago,
      updated_at: 9.seconds.ago
    )
    number_binding.update!(app_ref: 'legacy-router-app')
    number_binding.routing_policy.update!(
      mode: 'ai',
      ai_deployment_mode: 'onelink_managed',
      ai_app_ref: 'legacy-fonoster-ai-app',
      fonoster_ai_app_ref: 'legacy-fonoster-ai-app',
      onelink_ai_app_ref: 'direct-onelink-ai-app',
      fallback_mode: 'app'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'recursive-direct-runtime-leg',
             ingress_number: voice_channel.phone_number,
             caller_number: caller_number,
             app_ref: 'direct-onelink-ai-app'
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'reject',
      'reason' => 'recursive_runtime_call_active',
      'bridge_call_ref' => 'active-direct-runtime-leg'
    )
    expect(response.parsed_body).not_to have_key('app_ref')
  end

  it 'keeps legacy Fonoster AI app ref as fallback when OneLink app ref is not configured' do
    number_binding.routing_policy.update!(
      mode: 'ai',
      ai_deployment_mode: 'onelink_managed',
      ai_app_ref: 'legacy-fonoster-ai-app',
      fonoster_ai_app_ref: 'legacy-fonoster-ai-app',
      onelink_ai_app_ref: nil,
      fallback_mode: 'reject'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-onelink-ai-fallback',
             ingress_number: voice_channel.phone_number,
             caller_number: '+15557777778'
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'ai',
      'app_ref' => 'legacy-fonoster-ai-app',
      'reason' => 'ai_route'
    )
  end

  it 'returns the out of office reject message when the inbox is closed' do
    number_binding.routing_policy.update!(
      mode: 'operator',
      operator_agent_aor: 'sip:1003@example.test',
      fallback_mode: 'ai',
      ai_app_ref: 'out-of-office-ai-app',
      fallback_message: 'Fallback reject'
    )
    voice_inbox.update!(
      working_hours_enabled: true,
      out_of_office_message: 'We are closed now'
    )
    today_working_hour = voice_inbox.working_hours.find_by!(
      day_of_week: Time.zone.now.in_time_zone(voice_inbox.timezone).wday
    )
    today_working_hour.update!(
      closed_all_day: true,
      open_all_day: false,
      open_hour: nil,
      open_minutes: nil,
      close_hour: nil,
      close_minutes: nil
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-3',
             ingress_number: voice_channel.phone_number,
             caller_number: '+15551237777'
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'reject',
      'message' => 'We are closed now',
      'reason' => 'out_of_office'
    )
    expect(response.parsed_body).not_to have_key('app_ref')
  end

  it 'rejects recursive runtime app routes instead of returning the ingress runtime app ref' do
    number_binding.routing_policy.update!(
      mode: 'app',
      fallback_mode: 'reject',
      fallback_message: 'Handled safely'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-recursive',
             ingress_number: voice_channel.phone_number,
             caller_number: '+15551230099',
             app_ref: number_binding.configured_app_ref
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'reject',
      'reason' => 'recursive_runtime_app_ref',
      'message' => 'Handled safely'
    )
  end

  it 'writes inbound route request and response to the dedicated telephony debug log' do
    debug_log_file = Tempfile.new('telephony-route-debug')
    number_binding.routing_policy.update!(mode: 'app')

    with_modified_env(
      TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret',
      TELEPHONY_DEBUG_LOGGING: 'true',
      TELEPHONY_BRIDGE_DEBUG_LOG_PATH: debug_log_file.path
    ) do
      post path,
           params: {
             call_ref: 'inbound-route-log-1',
             ingress_number: voice_channel.phone_number,
             caller_number: '+15551234444'
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret',
             'X-Account-Id' => account.id.to_s
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)

    written_events = File.readlines(debug_log_file.path).map { |line| JSON.parse(line) }
    expect(written_events).to include(
      include(
        'event' => 'telephony_inbound_route_request',
        'path' => path,
        'call_ref' => 'inbound-route-log-1',
        'account_id' => account.id.to_s
      ),
      include(
        'event' => 'telephony_inbound_route_response',
        'path' => path,
        'call_ref' => 'inbound-route-log-1',
        'response_payload' => include('action' => 'app', 'app_ref' => number_binding.configured_app_ref)
      )
    )
  ensure
    debug_log_file&.close!
  end
end
