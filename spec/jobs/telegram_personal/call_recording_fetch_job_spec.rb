# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TelegramPersonal::CallRecordingFetchJob do
  include ActiveJob::TestHelper

  let(:account) { create(:account, call_transcriptions: true) }
  let(:channel) { create(:channel_telegram_personal, account: account) }
  let(:inbox) { channel.inbox }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox, source_id: '771122') }
  let(:conversation) do
    create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
  end
  let(:gateway_client) { instance_double(TelegramPersonal::GatewayClient) }

  before do
    Current.suppress_runtime_events = true
    Conversation.skip_callback(:create, :before, :determine_conversation_status)
    Conversation.skip_callback(:commit, :after, :notify_conversation_creation)
    allow(TelegramPersonal::GatewayClient).to receive(:new).and_return(gateway_client)
  end

  after do
    Conversation.set_callback(:commit, :after, :notify_conversation_creation, on: :create)
    Conversation.set_callback(:create, :before, :determine_conversation_status)
    Current.suppress_runtime_events = nil
  end

  it 'downloads combined Ogg recording, attaches it to Call, updates voice_call message, and enqueues transcription' do
    call = Call.create!(
      provider: :telegram_personal, account: account, inbox: inbox, conversation: conversation,
      contact: contact, provider_call_id: 'tg-rec-1', media_session_id: 'tg-rec-sess-1',
      direction: :incoming, status: 'completed', duration_seconds: 15
    )
    msg = TelegramPersonal::CallMessageBuilder.create!(conversation: conversation, call: call)
    call.update!(message_id: msg.id)

    expect(gateway_client).to receive(:download_call_recording!).with(
      call_ref: 'tg-rec-sess-1', side: 'combined'
    ).and_return("OggS#{'x' * 512}")

    expect do
      described_class.perform_now(call.id)
    end.to have_enqueued_job(Whatsapp::CallTranscriptionJob).with(call.id)

    call.reload
    expect(call.recording).to be_attached
    expect(call.recording.blob.content_type).to eq('audio/ogg')
    expect(msg.reload.content_attributes.dig('data', 'recording_url')).to be_present
  end

  it 'falls back to customer track when combined returns 404' do
    account.update!(call_transcriptions: false)
    call = Call.create!(
      provider: :telegram_personal, account: account, inbox: inbox, conversation: conversation,
      contact: contact, provider_call_id: 'tg-rec-2', media_session_id: 'tg-rec-sess-2',
      direction: :incoming, status: 'completed'
    )

    not_found = TelegramPersonal::GatewayClient::GatewayError.new('Not found', http_status: 404)
    expect(gateway_client).to receive(:download_call_recording!).with(
      call_ref: 'tg-rec-sess-2', side: 'combined'
    ).and_raise(not_found)
    expect(gateway_client).to receive(:download_call_recording!).with(
      call_ref: 'tg-rec-sess-2', side: 'customer'
    ).and_return("OggS#{'y' * 512}")

    expect do
      described_class.perform_now(call.id)
    end.not_to have_enqueued_job(Whatsapp::CallTranscriptionJob)

    expect(call.reload.recording).to be_attached
  end

  it 'attaches recording for human operators but skips AI transcription when explicit AI consent is required and not granted' do
    allow(Compliance::ExplicitAiConsentGate).to receive(:blocked?).with(conversation).and_return(true)
    call = Call.create!(
      provider: :telegram_personal, account: account, inbox: inbox, conversation: conversation,
      contact: contact, provider_call_id: 'tg-rec-consent', media_session_id: 'tg-rec-sess-consent',
      direction: :incoming, status: 'completed'
    )

    expect(gateway_client).to receive(:download_call_recording!).with(
      call_ref: 'tg-rec-sess-consent', side: 'combined'
    ).and_return("OggS#{'c' * 512}")

    expect do
      described_class.perform_now(call.id)
    end.not_to have_enqueued_job(Whatsapp::CallTranscriptionJob)

    expect(call.reload.recording).to be_attached
    expect(Whatsapp::CallTranscriptionService.new(call).perform).to eq(error: 'AI consent required')
  end
end
