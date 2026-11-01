require 'rails_helper'

RSpec.describe TelegramCalls::ClaimCoordinator do
  let(:account) { create(:account, name: 'OneLink Clinic') }
  let(:agent_one) { create(:user, account: account, role: :agent, name: 'Жанар') }
  let(:agent_two) { create(:user, account: account, role: :agent, name: 'Шерхан') }
  let!(:contact) { create(:contact, account: account, name: 'Семен Клиент', phone_number: '+77015551122') }
  let(:bot_client) do
    instance_double(
      TelegramCalls::BotClient,
      send_message: { 'message_id' => 901 },
      edit_message_text: true,
      answer_callback_query: true
    )
  end
  let(:gateway_client) do
    instance_double(
      TelegramCalls::GatewaySoftphoneClient,
      configured?: true,
      create_leg!: { 'ok' => true },
      attach_webrtc!: { 'sdp_answer' => 'v=0-answer-sdp' },
      bridge_telegram!: { 'ok' => true },
      bridge_sip!: { 'ok' => true },
      dial_sip!: { 'ok' => true },
      terminate_leg!: { 'ok' => true },
      decline_sip_call!: { 'ok' => true },
      remove_sip_line_group!: { 'ok' => true },
      download_recording!: 'OggS-fake-opus-stream'
    )
  end

  before do
    allow(TelegramCalls::Config).to receive_messages(
      bot_token: '123456:TEST_BOT_TOKEN',
      bot_username: 'onelink_calls_bot',
      gateway_url: 'http://gateway.internal:8790',
      gateway_token: 'gw-secret',
      callback_token: 'cb-secret',
      frontend_url: 'https://app.one-link.kz'
    )
    allow(TelegramCalls::BotClient).to receive(:new).and_return(bot_client)
    allow(TelegramCalls::GatewaySoftphoneClient).to receive(:new).and_return(gateway_client)

    Telephony::TelegramOperatorBinding.create!(
      account: account, user: agent_one, telegram_user_id: '1001',
      telegram_chat_id: '1001', username: 'zhanar_tg', verified_at: Time.current, on_line: true
    )
    Telephony::TelegramOperatorBinding.create!(
      account: account, user: agent_two, telegram_user_id: '1002',
      telegram_chat_id: '1002', username: 'sherkhan_tg', verified_at: Time.current, on_line: true
    )
  end

  describe 'WhatsApp Business incoming call consolidation and race claim' do
    let(:wa_inbox) { create(:inbox, account: account, name: 'WhatsApp Main') }
    let(:conversation) { create(:conversation, account: account, inbox: wa_inbox, contact: contact) }
    let(:call) do
      Call.create!(
        account: account, inbox: wa_inbox, conversation: conversation, contact: contact,
        provider: :whatsapp, provider_call_id: 'wacid.test.001',
        direction: :incoming, status: 'ringing', media_session_id: 'ms-wa-001',
        meta: { 'media_server' => true }
      )
    end

    it 'sends exact CreateOperatorLegPayload fields, bridges first answerer, and cancels second leg' do
      wa_service = instance_double(
        Whatsapp::CallService,
        accept: true,
        agent_offer: { 'sdp_offer' => 'v=0-offer-sdp', 'peer_id' => 'peer-1', 'ice_servers' => [] }
      )
      media_client = instance_double(Whatsapp::MediaServerClient, set_agent_answer: true)
      allow(Call).to receive(:media_server_enabled?).and_return(true)
      allow(Whatsapp::CallService).to receive(:new).and_return(wa_service)
      allow(Whatsapp::MediaServerClient).to receive(:new).and_return(media_client)

      legs = TelegramCalls::CallDispatcher.dispatch_whatsapp_call(call)
      expect(legs.size).to eq(2)
      expect(gateway_client).to have_received(:create_leg!).with(
        hash_including(
          source_type: 'whatsapp',
          source_call_ref: call.id.to_s,
          account_id: account.id,
          user_id: agent_one.id,
          operator_telegram_user_id: '1001',
          operator_telegram_username: 'zhanar_tg',
          metadata: hash_including(caller_label: 'Семен Клиент')
        )
      )

      win_leg = legs.find { |item| item['user_id'] == agent_one.id }
      lose_leg = legs.find { |item| item['user_id'] == agent_two.id }

      result = described_class.new(payload: { event_type: 'operator_leg.answered', leg_id: win_leg['leg_id'] }).perform
      expect(result).to eq(ok: true, claimed: true)
      expect(media_client).to have_received(:set_agent_answer).with(
        'ms-wa-001', sdp_answer: 'v=0-answer-sdp', peer_id: 'peer-1'
      )
      expect(gateway_client).to have_received(:terminate_leg!).with(
        leg_id: lose_leg['leg_id'], reason: 'cancelled_elsewhere'
      )

      late = described_class.new(payload: { event_type: 'operator_leg.answered', leg_id: lose_leg['leg_id'] }).perform
      expect(late).to eq(ok: true, claimed: false)
    end
  end

  describe 'Telegram Personal incoming call zero-hop PCM bridge' do
    let(:tgp_inbox) { create(:inbox, account: account, name: 'Личный Telegram') }
    let(:conversation) { create(:conversation, account: account, inbox: tgp_inbox, contact: contact) }
    let(:call) do
      Call.create!(
        account: account, inbox: tgp_inbox, conversation: conversation, contact: contact,
        provider: :telegram_personal, provider_call_id: "#{tgp_inbox.id}:tgp-raw-777",
        direction: :incoming, status: 'ringing'
      )
    end

    it 'reserves the Call atomically, bridges raw Telegram call_id, and terminates on hangup' do
      allow(TelegramPersonal::CallMessageBuilder).to receive(:update_status!)
      allow(TelegramPersonal::CallBroadcaster).to receive(:broadcast_accepted)
      tgp_service = instance_double(TelegramPersonal::CallService, terminate: true)
      allow(TelegramPersonal::CallService).to receive(:new).and_return(tgp_service)

      legs = TelegramCalls::CallDispatcher.dispatch_telegram_personal_call(call)
      win_leg = legs.find { |item| item['user_id'] == agent_one.id }

      result = described_class.new(payload: { event_type: 'operator_leg.answered', leg_id: win_leg['leg_id'] }).perform
      expect(result).to eq(ok: true, claimed: true)
      expect(call.reload.status).to eq('in_progress')
      expect(call.accepted_by_agent_id).to eq(agent_one.id)
      expect(gateway_client).to have_received(:bridge_telegram!).with(
        leg_id: win_leg['leg_id'],
        payload: { channel_id: tgp_inbox.channel.id, call_id: 'tgp-raw-777' }
      )

      end_res = described_class.new(
        payload: { event_type: 'operator_leg.ended', leg_id: win_leg['leg_id'], duration_seconds: 34 }
      ).perform
      expect(end_res).to eq(ok: true, ended: true)
      expect(tgp_service).to have_received(:terminate)
    end
  end

  describe 'SIP telephony incoming call bridge, idempotent recording upload, and SipEventProcessor contracts' do
    let(:voice_inbox) { create(:inbox, account: account, name: 'Altel SIP') }
    let(:call_session) do
      Telephony::CallSession.create!(
        account: account, inbox: voice_inbox, contact: contact,
        provider: 'wazo', external_call_ref: 'wazo:janus:10:janus-in-501',
        direction: 'inbound', status: 'ringing', from_number: '+77015551122', to_number: '+77070001122'
      )
    end

    it 'forwards janus_call_id on bridge_sip! and uploads recording at most once across hangup + leg_ended' do
      claim_svc = instance_double(Telephony::OperatorCallClaimService, perform: { claimed: true })
      ans_svc = instance_double(Telephony::OperatorCallAnsweredService, perform: true)
      rej_svc = instance_double(Telephony::OperatorCallRejectService, perform: true)
      allow(Telephony::OperatorCallClaimService).to receive(:new).and_return(claim_svc)
      allow(Telephony::OperatorCallAnsweredService).to receive(:new).and_return(ans_svc)
      allow(Telephony::OperatorCallRejectService).to receive(:new).and_return(rej_svc)
      allow(Telephony::BrowserRecordingUploadService).to receive(:perform!)

      legs = TelegramCalls::CallDispatcher.dispatch_telephony_call(
        call_session,
        line_key: 'account:1:user:1:binding:1:sip_profile:10',
        janus_call_id: 'janus-in-501',
        target_user_ids: [agent_one.id]
      )
      expect(legs.size).to eq(1)
      leg_id = legs.first['leg_id']

      ans_res = described_class.new(payload: { event_type: 'operator_leg.answered', leg_id: leg_id }).perform
      expect(ans_res).to eq(ok: true, claimed: true)
      expect(gateway_client).to have_received(:bridge_sip!).with(
        leg_id: leg_id,
        line_key: 'account:1:user:1:binding:1:sip_profile:10',
        janus_call_id: 'janus-in-501',
        call_ref: 'wazo:janus:10:janus-in-501'
      )

      # Simulate remote SIP hangup arriving BEFORE operator_leg.ended, both carrying has_recording: true
      described_class.new(
        payload: {
          event_type: 'sip_line.call_hangup',
          account_id: account.id,
          user_id: agent_one.id,
          leg_id: leg_id,
          call_ref: call_session.external_call_ref,
          has_recording: true,
          duration_seconds: 48
        }
      ).perform
      described_class.new(
        payload: { event_type: 'operator_leg.ended', leg_id: leg_id, has_recording: true, duration_seconds: 48 }
      ).perform

      expect(gateway_client).to have_received(:download_recording!).with(leg_id: leg_id).once
      expect(Telephony::BrowserRecordingUploadService).to have_received(:perform!).with(
        hash_including(call_session: call_session, duration_seconds: 48)
      ).once
    end

    it 'skips human CallDispatcher when ai_voice handles incoming SIP call' do
      webphone_svc = instance_double(
        Telephony::WebphoneService,
        report_browser_sip_incoming!: { call_ref: call_session.external_call_ref, ai_voice: { attached: true } }
      )
      allow(Telephony::WebphoneService).to receive(:new).and_return(webphone_svc)

      ai_res = described_class.new(
        payload: {
          event_type: 'sip_line.incoming_call',
          account_id: account.id, user_id: agent_one.id, inbox_id: voice_inbox.id,
          line_key: 'l-wazo', janus_call_id: 'janus-ai-1', from_uri: 'sip:+77015551122@pbx.test'
        }
      ).perform
      expect(ai_res).to eq(ok: true, call_ref: call_session.external_call_ref, ai_voice: true)
      expect(gateway_client).not_to have_received(:create_leg!)
    end

    it 'maps Gateway sip_line.incoming_call fields and cancels ringing hangup by janus_call_id' do
      webphone_svc = instance_double(
        Telephony::WebphoneService,
        report_browser_sip_incoming!: { call_ref: call_session.external_call_ref }
      )
      rej_svc = instance_double(Telephony::OperatorCallRejectService, perform: true)
      allow(Telephony::WebphoneService).to receive(:new).and_return(webphone_svc)
      allow(Telephony::OperatorCallRejectService).to receive(:new).and_return(rej_svc)

      in_res = described_class.new(
        payload: {
          event_type: 'sip_line.incoming_call',
          account_id: account.id, user_id: agent_one.id, inbox_id: voice_inbox.id,
          line_key: 'l-wazo', provider: 'wazo', janus_call_id: 'janus-in-501',
          from_uri: 'sip:+77015551122@pbx.test'
        }
      ).perform
      expect(in_res).to eq(ok: true, call_ref: call_session.external_call_ref)
      expect(webphone_svc).to have_received(:report_browser_sip_incoming!).with(
        hash_including(
          user: agent_one, inbox: voice_inbox,
          params: hash_including('call_ref' => 'janus-in-501', 'from_number' => '+77015551122')
        )
      )

      described_class.new(
        payload: {
          event_type: 'sip_line.call_hangup',
          account_id: account.id, user_id: agent_one.id,
          line_key: 'l-wazo', call_ref: nil, janus_call_id: 'janus-in-501'
        }
      ).perform
      expect(rej_svc).to have_received(:perform)
    end

    it 'yields Telegram SIP line and sets binding off_line when browser takes over lease on heartbeat' do
      binding = account.telephony_telegram_operator_bindings.find_by!(user_id: agent_one.id)
      binding.update!(sip_lease_meta: { 'group_key' => 'grp-yield-1', 'lines' => [{ 'line_key' => 'l1', 'registered' => true }] })
      webphone_svc = instance_double(
        Telephony::WebphoneService,
        update_presence!: { presence_update_accepted: false, reason: 'sip_profile_registration_lease_conflict' }
      )
      allow(Telephony::WebphoneService).to receive(:new).and_return(webphone_svc)

      described_class.new(
        payload: {
          event_type: 'sip_line.heartbeat',
          account_id: account.id,
          user_id: agent_one.id,
          inbox_id: voice_inbox.id,
          registered: true
        }
      ).perform

      expect(gateway_client).to have_received(:remove_sip_line_group!).with(group_key: 'grp-yield-1')
      expect(binding.reload).not_to be_on_line
    end
  end

  describe 'SipLineSyncService wire contract and lease rollback' do
    let(:voice_inbox) { create(:inbox, account: account, name: 'Wazo Trunk') }

    let(:webphone_session_fixture) do
      {
        provider: 'wazo', inbox_id: voice_inbox.id, sip_profile_id: 83,
        session_key: 'sip_profile:83', janus_server: 'wss://janus.test/ws',
        sip: { username: '183', host: 'pbx.test' },
        registration_instance_id: 'reg-83', registration_config_version: 4,
        registration_release_key: 'rel-secret-83'
      }
    end

    it 'sends SyncOperatorSipLinesPayload schema and forwards janus IDs to update_presence!' do
      account.enable_features!(:channel_voice)
      binding = account.telephony_telegram_operator_bindings.find_by!(user_id: agent_one.id)
      group_key = "account:#{account.id}:user:#{agent_one.id}:binding:#{binding.id}"
      expected_line_key = "#{group_key}:sip_profile:83"
      webphone_svc = instance_double(
        Telephony::WebphoneService,
        token_for: { webphone_sessions: [webphone_session_fixture] },
        update_presence!: { presence_update_accepted: true }
      )
      allow(Telephony::WebphoneService).to receive(:new).and_return(webphone_svc)
      allow(gateway_client).to receive(:sync_sip_lines!).and_return(
        'ok' => true,
        'registered_lines' => [{ 'line_key' => expected_line_key, 'registered' => true, 'janus_session_id' => 9101, 'janus_handle_id' => 9202 }],
        'errors' => {}
      )

      res = TelegramCalls::SipLineSyncService.new(binding: binding, gateway_client: gateway_client).activate!
      expect(res[:synced_lines]).to eq(1)
      expect(gateway_client).to have_received(:sync_sip_lines!).with(
        hash_including(
          line_group_key: group_key, account_id: account.id, user_id: agent_one.id,
          operator_telegram_user_id: '1001',
          sessions: [hash_including('session_key' => 'sip_profile:83', 'provider' => 'wazo')]
        )
      )
      expect(webphone_svc).to have_received(:update_presence!).with(
        hash_including(
          registered: true,
          registration_context: hash_including('janus_session_id' => 9101, 'janus_handle_id' => 9202)
        )
      )
    end

    it 'rolls back webphone lease and raises Telephony::Error when 0 SIP lines register' do
      account.enable_features!(:channel_voice)
      binding = account.telephony_telegram_operator_bindings.find_by!(user_id: agent_one.id)
      expected_line_key = "account:#{account.id}:user:#{agent_one.id}:binding:#{binding.id}:sip_profile:83"
      webphone_svc = instance_double(
        Telephony::WebphoneService,
        token_for: { webphone_sessions: [webphone_session_fixture] },
        update_presence!: { presence_update_accepted: true },
        release_registration_lease!: true
      )
      allow(Telephony::WebphoneService).to receive(:new).and_return(webphone_svc)
      allow(gateway_client).to receive(:sync_sip_lines!).and_return(
        'ok' => false, 'registered_lines' => [], 'errors' => { expected_line_key => 'SIP 401 Unauthorized' }
      )

      expect do
        TelegramCalls::SipLineSyncService.new(binding: binding, gateway_client: gateway_client).activate!
      end.to raise_error(Telephony::Error, /SIP 401 Unauthorized/)
      expect(webphone_svc).to have_received(:release_registration_lease!).with(release_key: 'rel-secret-83')
    end
  end

  describe 'Outbound dial from Telegram bot (/call +7...)' do
    let(:voice_inbox) { create(:inbox, account: account, name: 'Sipuni Trunk') }

    it 'normalizes 8701... to +7701..., dials SIP upon answer, updates card on call_accepted, and cleans up on dial failure' do
      binding = account.telephony_telegram_operator_bindings.find_by!(user_id: agent_one.id)
      binding.update!(
        sip_lease_meta: {
          'group_key' => 'g1',
          'lines' => [{ 'line_key' => 'l-sipuni', 'inbox_id' => voice_inbox.id, 'provider' => 'sipuni', 'registered' => true }]
        }
      )
      outbound_session = Telephony::CallSession.create!(
        account: account, inbox: voice_inbox, provider: 'sipuni',
        external_call_ref: 'sipuni:janus:tgout:test', direction: 'outbound',
        status: 'ringing', to_number: '+77015551122',
        metadata: { 'chatwoot_user_id' => agent_one.id }
      )
      ingestion_svc = instance_double(Telephony::EventsIngestionService, perform: outbound_session)
      ans_svc = instance_double(Telephony::OperatorCallAnsweredService, perform: { answered: true })
      allow(Telephony::EventsIngestionService).to receive(:new).and_return(ingestion_svc)
      allow(Telephony::OperatorCallAnsweredService).to receive(:new).and_return(ans_svc)

      leg_meta = TelegramCalls::OutboundDialService.new(binding: binding, raw_number: '8 (701) 555-11-22').perform!
      expect(leg_meta['caller_phone']).to eq('+77015551122')
      expect(gateway_client).to have_received(:create_leg!).with(
        hash_including(
          source_type: 'telephony_sip_outbound',
          operator_telegram_user_id: '1001',
          metadata: hash_including(caller_label: 'Семен Клиент')
        )
      )

      res = described_class.new(payload: { event_type: 'operator_leg.answered', leg_id: leg_meta['leg_id'] }).perform
      expect(res).to eq(ok: true, call_ref: outbound_session.external_call_ref)
      expect(gateway_client).to have_received(:dial_sip!).with(
        leg_id: leg_meta['leg_id'], line_key: 'l-sipuni',
        number: '+77015551122', call_ref: outbound_session.external_call_ref
      )

      # Callee 200 OK -> marks CallSession answered and updates Telegram card to Разговор идёт
      described_class.new(
        payload: {
          event_type: 'sip_line.call_accepted',
          account_id: account.id,
          user_id: agent_one.id,
          leg_id: leg_meta['leg_id'],
          call_ref: outbound_session.external_call_ref
        }
      ).perform
      expect(ans_svc).to have_received(:perform)
      expect(bot_client).to have_received(:edit_message_text).with(
        hash_including(text: include('Разговор идёт'))
      )
    end
  end
end
