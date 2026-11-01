require 'rails_helper'

RSpec.describe 'Webhooks::TelegramCallsBot', type: :request do
  let(:account) { create(:account, name: 'OD Coworking') }
  let(:user) { create(:user, account: account, role: :agent) }
  let(:bot_client) do
    instance_double(
      TelegramCalls::BotClient,
      send_message: { 'message_id' => 101 },
      edit_message_text: true,
      answer_callback_query: true
    )
  end
  let(:sync_service) do
    instance_double(
      TelegramCalls::SipLineSyncService,
      activate!: { synced_lines: 0 },
      deactivate!: { deactivated: true }
    )
  end

  before do
    allow(TelegramCalls::Config).to receive_messages(
      bot_token: '123456:TEST_BOT_TOKEN',
      bot_username: 'onelink_calls_bot',
      webhook_secret: 'wh-secret-999'
    )
    allow(TelegramCalls::BotClient).to receive(:new).and_return(bot_client)
    allow(TelegramCalls::SipLineSyncService).to receive(:new).and_return(sync_service)
  end

  it 'authenticates X-Telegram-Bot-Api-Secret-Token header on /webhooks/telegram_calls_bot and rejects wrong secrets' do
    post '/webhooks/telegram_calls_bot', params: { message: { text: '/status' } }
    expect(response).to have_http_status(:unauthorized)

    post '/webhooks/telegram_calls_bot',
         params: { message: { chat: { id: 500_111 }, from: { id: 500_111 }, text: '/status' } },
         headers: { 'X-Telegram-Bot-Api-Secret-Token' => 'wh-secret-999' }
    expect(response).to have_http_status(:ok)
  end

  it 'consumes /start token and toggles operator line on and off' do
    binding = Telephony::TelegramOperatorBinding.create!(account: account, user: user)
    issued = binding.issue_link_token!

    post '/webhooks/telegram_calls_bot',
         params: {
           message: {
             chat: { id: 500_111 },
             from: { id: 500_111, username: 'zhanar_op', first_name: 'Zhanar' },
             text: "/start #{issued[:token]}"
           }
         },
         headers: { 'X-Telegram-Bot-Api-Secret-Token' => 'wh-secret-999' }
    expect(response).to have_http_status(:ok)
    expect(binding.reload).to be_connected

    post '/webhooks/telegram_calls_bot/wh-secret-999', params: {
      message: { chat: { id: 500_111 }, from: { id: 500_111 }, text: TelegramCalls::BotClient::ON_LINE_BUTTON }
    }
    expect(binding.reload).to be_on_line

    post '/webhooks/telegram_calls_bot/wh-secret-999', params: {
      message: { chat: { id: 500_111 }, from: { id: 500_111 }, text: TelegramCalls::BotClient::OFF_LINE_BUTTON }
    }
    expect(binding.reload).not_to be_on_line
  end

  it 'rescues Telephony::Error on go_on_line! and sends warning to operator without HTTP 500' do
    binding = Telephony::TelegramOperatorBinding.create!(
      account: account, user: user, telegram_user_id: '500111',
      telegram_chat_id: '500111', verified_at: Time.current, on_line: false
    )
    allow(sync_service).to receive(:activate!).and_raise(
      Telephony::Error.new(code: 'TELEGRAM_SIP_REGISTRATION_FAILED', message: 'SIP 403 Forbidden', status: :unprocessable_content)
    )

    post '/webhooks/telegram_calls_bot',
         params: {
           message: { chat: { id: 500_111 }, from: { id: 500_111 }, text: TelegramCalls::BotClient::ON_LINE_BUTTON }
         },
         headers: { 'X-Telegram-Bot-Api-Secret-Token' => 'wh-secret-999' }
    expect(response).to have_http_status(:ok)
    expect(binding.reload).not_to be_on_line
    expect(bot_client).to have_received(:send_message).with(
      hash_including(chat_id: '500111', text: include('SIP 403 Forbidden'))
    )
  end

  it 'prompts workspace selection when operator has active SIP lines in multiple workspaces' do
    second_account = create(:account, name: 'Sezim Clinic')
    second_user = create(:user, account: second_account, role: :agent)
    b1 = Telephony::TelegramOperatorBinding.create!(
      account: account, user: user, telegram_user_id: '500111',
      telegram_chat_id: '500111', verified_at: Time.current, on_line: true,
      sip_lease_meta: { 'lines' => [{ 'line_key' => 'l1', 'registered' => true }] }
    )
    b2 = Telephony::TelegramOperatorBinding.create!(
      account: second_account, user: second_user, telegram_user_id: '500111',
      telegram_chat_id: '500111', verified_at: Time.current, on_line: true,
      sip_lease_meta: { 'lines' => [{ 'line_key' => 'l2', 'registered' => true }] }
    )
    dial_svc = instance_double(TelegramCalls::OutboundDialService, perform!: { 'leg_id' => 'out-1' })
    allow(TelegramCalls::OutboundDialService).to receive(:new).and_return(dial_svc)

    post '/webhooks/telegram_calls_bot',
         params: { message: { chat: { id: 500_111 }, from: { id: 500_111 }, text: '/call +77015551122' } },
         headers: { 'X-Telegram-Bot-Api-Secret-Token' => 'wh-secret-999' }
    expect(response).to have_http_status(:ok)
    expect(TelegramCalls::OutboundDialService).not_to have_received(:new)
    expect(bot_client).to have_received(:send_message).with(
      hash_including(
        reply_markup: {
          inline_keyboard: [
            [{ text: "📞 #{b1.account.name}", callback_data: "dialws:#{b1.id}:77015551122" }],
            [{ text: "📞 #{b2.account.name}", callback_data: "dialws:#{b2.id}:77015551122" }]
          ]
        }
      )
    )

    post '/webhooks/telegram_calls_bot',
         params: { callback_query: { id: 'cb-ws', from: { id: 500_111 }, data: "dialws:#{b2.id}:77015551122" } },
         headers: { 'X-Telegram-Bot-Api-Secret-Token' => 'wh-secret-999' }
    expect(response).to have_http_status(:ok)
    expect(TelegramCalls::OutboundDialService).to have_received(:new).with(binding: b2, raw_number: '+77015551122')
  end

  it 'verifies own contact share and blocks third-party contact spoofing' do
    binding = Telephony::TelegramOperatorBinding.create!(
      account: account, user: user, telegram_user_id: '500111',
      telegram_chat_id: '500111', verified_at: Time.current
    )

    post '/webhooks/telegram_calls_bot/wh-secret-999', params: {
      message: {
        chat: { id: 500_111 },
        from: { id: 500_111 },
        contact: { user_id: 999_888, phone_number: '+77019998877' }
      }
    }
    expect(binding.reload.phone_number).to be_nil

    post '/webhooks/telegram_calls_bot/wh-secret-999', params: {
      message: {
        chat: { id: 500_111 },
        from: { id: 500_111 },
        contact: { user_id: 500_111, phone_number: '+77011112233' }
      }
    }
    expect(binding.reload.phone_number).to eq('+77011112233')
  end

  it 'authorizes callback query reject/hangup and uploads SIP recording on bot hangup button' do
    voice_inbox = create(:inbox, account: account, name: 'Wazo Line')
    call_session = Telephony::CallSession.create!(
      account: account, inbox: voice_inbox, provider: 'wazo',
      external_call_ref: 'wazo:janus:hangup-btn-1', direction: 'inbound',
      status: 'in_progress', answered_at: 20.seconds.ago
    )
    binding = Telephony::TelegramOperatorBinding.create!(
      account: account, user: user, telegram_user_id: '500111',
      telegram_chat_id: '500111', verified_at: Time.current, on_line: true
    )
    gw_client = instance_double(
      TelegramCalls::GatewaySoftphoneClient,
      configured?: true,
      terminate_leg!: { 'ok' => true, 'has_recording' => true, 'duration_seconds' => 27 },
      download_recording!: 'OggS-bot-hangup-stream'
    )
    allow(TelegramCalls::GatewaySoftphoneClient).to receive(:new).and_return(gw_client)
    allow(Telephony::BrowserRecordingUploadService).to receive(:perform!)
    allow(Telephony::OperatorCallRejectService).to receive(:new).and_return(
      instance_double(Telephony::OperatorCallRejectService, perform: true)
    )

    TelegramCalls::Registry.store_leg!(
      'leg_id' => 'leg-cb-1', 'binding_id' => binding.id, 'user_id' => user.id,
      'account_id' => account.id, 'source_type' => 'telephony_sip',
      'source_call_ref' => call_session.external_call_ref,
      'chat_id' => '500111', 'message_id' => 101, 'status' => 'in_progress',
      'claimed' => true, 'voice_ring_started' => true
    )

    post '/webhooks/telegram_calls_bot/wh-secret-999', params: {
      callback_query: { id: 'cb-bad', from: { id: 888_777 }, data: 'hangup:leg-cb-1' }
    }
    expect(TelegramCalls::Registry.fetch_leg('leg-cb-1')['status']).to eq('in_progress')

    post '/webhooks/telegram_calls_bot/wh-secret-999', params: {
      callback_query: { id: 'cb-ok', from: { id: 500_111 }, data: 'hangup:leg-cb-1' }
    }
    expect(TelegramCalls::Registry.fetch_leg('leg-cb-1')['status']).to eq('ended')
    expect(Telephony::BrowserRecordingUploadService).to have_received(:perform!).with(
      hash_including(call_session: call_session, duration_seconds: 27)
    )
  end
end
