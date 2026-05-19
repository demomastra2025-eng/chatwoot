require 'rails_helper'

RSpec.describe Whatsapp::AiVoiceCallService do
  let(:account) { create(:account) }
  let(:channel) do
    create(
      :channel_whatsapp,
      account: account,
      provider: 'whatsapp_cloud',
      provider_config: {
        'source' => 'embedded_signup',
        'calling_enabled' => true,
        'media_server_enabled' => true,
        'ai_voice_enabled' => true
      },
      validate_provider_config: false,
      sync_templates: false
    )
  end
  let(:inbox) { channel.inbox }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, :with_phone_number, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, status: 'pending') }
  let(:call) do
    create(
      :call,
      account: account,
      inbox: inbox,
      contact: contact,
      conversation: conversation,
      provider: :whatsapp,
      direction: :incoming,
      status: 'ringing',
      meta: { 'sdp_offer' => 'meta-offer', 'ice_servers' => [] }
    )
  end
  let(:routing_decision) { Whatsapp::CallRoutingService.new(call: call).perform }
  let(:provider) { double('provider') }
  let(:media_client) { instance_double(Whatsapp::MediaServerClient) }
  let(:runtime_client) { instance_double(Whatsapp::AiVoiceRuntimeClient, enabled?: true) }

  before do
    Current.suppress_runtime_events = true
    Conversation.skip_callback(:create, :before, :determine_conversation_status)
    Conversation.skip_callback(:commit, :after, :notify_conversation_creation)
    account.enable_features!('whatsapp_call')
    create(:captain_inbox, inbox: inbox, captain_assistant: assistant)
    allow_any_instance_of(Channel::Whatsapp).to receive(:provider_service).and_return(provider)
    allow(Whatsapp::MediaServerClient).to receive(:new).and_return(media_client)
    allow(Whatsapp::AiVoiceRuntimeClient).to receive(:new).and_return(runtime_client)
    allow(ActionCable.server).to receive(:broadcast)
    allow(Whatsapp::CallMessageBuilder).to receive(:update_status!)
  end

  after do
    Conversation.set_callback(:commit, :after, :notify_conversation_creation, on: :create)
    Conversation.set_callback(:create, :before, :determine_conversation_status)
    Current.suppress_runtime_events = nil
  end

  it 'answers an inbound WhatsApp call for the AI voice agent and records runtime handoff state' do
    expect(media_client).to receive(:create_session).with(
      call_id: call.provider_call_id,
      direction: 'incoming',
      sdp_offer: 'meta-offer',
      ice_servers: [],
      account_id: account.id
    ).and_return({ 'session_id' => 'media-ai-1', 'meta_sdp_answer' => 'meta-answer' })
    expect(provider).to receive(:pre_accept_call).with(call.provider_call_id, 'meta-answer').and_return(true)
    expect(provider).to receive(:accept_call).with(call.provider_call_id, 'meta-answer').and_return(true)
    expect(media_client).to receive(:create_runtime_agent).with(
      'media-ai-1',
      call_ref: "whatsapp:#{call.provider_call_id}",
      account_id: account.id,
      conversation_id: conversation.id,
      inbox_id: inbox.id
    ).and_return(
      {
        'runtime_session_id' => 'rt-wa-1',
        'stream_url' => 'ws://media-server/sessions/media-ai-1/runtime-stream?token=redacted',
        'codec' => 'pcm_s16le',
        'input_sample_rate' => 16_000,
        'output_sample_rate' => 24_000
      }
    )
    expect(runtime_client).to receive(:attach_call).with(
      hash_including(
        call_ref: "whatsapp:#{call.provider_call_id}",
        account_id: account.id,
        inbox_id: inbox.id,
        conversation_id: conversation.id,
        whatsapp_call_id: call.id,
        provider_call_id: call.provider_call_id,
        media_session_id: 'media-ai-1',
        runtime_stream: hash_including(
          'runtime_session_id' => 'rt-wa-1',
          'codec' => 'pcm_s16le',
          'input_sample_rate' => 16_000,
          'output_sample_rate' => 24_000
        ),
        routing: hash_including(
          action: 'ai_accept',
          reason: 'conversation_pending_ai_voice_enabled'
        )
      )
    ).and_return({ 'status' => 'accepted', 'runtime_session_id' => 'rt-wa-1' })

    with_modified_env(MEDIA_SERVER_URL: 'http://media-server:4000', MEDIA_SERVER_AUTH_TOKEN: 'secret') do
      described_class.new(call: call, routing_decision: routing_decision).perform
    end

    call.reload
    expect(call.status).to eq('in_progress')
    expect(call.media_session_id).to eq('media-ai-1')
    expect(call.started_at).to be_present
    expect(call.meta['ai_voice']).to include(
      'state' => 'answered',
      'captain_assistant_id' => assistant.id,
      'runtime_transport' => 'whatsapp_cloud',
      'call_ref' => "whatsapp:#{call.provider_call_id}",
      'media_session_id' => 'media-ai-1',
      'runtime_session_id' => 'rt-wa-1'
    )
    call_session = account.telephony_call_sessions.find_by!(external_call_ref: "whatsapp:#{call.provider_call_id}")
    expect(call_session).to have_attributes(
      provider: 'whatsapp_cloud',
      status: 'in_progress',
      direction: 'inbound',
      conversation_id: conversation.id,
      contact_id: contact.id,
      inbox_id: inbox.id,
      answered_by: 'ai_agent'
    )
    expect(call_session.metadata['ai_voice']).to include(
      'transport' => 'whatsapp_cloud',
      'media_session_id' => 'media-ai-1',
      'runtime_session_id' => 'rt-wa-1'
    )
    expect(call.conversation.additional_attributes).to include('call_status' => 'ai_answered', 'call_direction' => 'inbound')
    expect(ActionCable.server).to have_received(:broadcast).with(
      "account_#{account.id}",
      hash_including(event: 'whatsapp_call.ai_answering', data: hash_including(call_id: call.provider_call_id))
    )
    expect(ActionCable.server).to have_received(:broadcast).with(
      "account_#{account.id}",
      hash_including(event: 'whatsapp_call.ai_answered', data: hash_including(call_id: call.provider_call_id, media_session_id: 'media-ai-1'))
    )
  end

  it 'fails closed and cleans up when media-server runtime contract creation fails after Meta accepted the call' do
    expect(media_client).to receive(:create_session).and_return({ 'session_id' => 'media-ai-2', 'meta_sdp_answer' => 'meta-answer' })
    expect(provider).to receive(:pre_accept_call).with(call.provider_call_id, 'meta-answer').and_return(true)
    expect(provider).to receive(:accept_call).with(call.provider_call_id, 'meta-answer').and_return(true)
    expect(media_client).to receive(:create_runtime_agent).and_raise(Whatsapp::MediaServerClient::SessionError, 'runtime attach failed')
    expect(runtime_client).not_to receive(:attach_call)
    expect(provider).to receive(:terminate_call).with(call.provider_call_id)
    expect(media_client).to receive(:terminate_session).with('media-ai-2')

    with_modified_env(MEDIA_SERVER_URL: 'http://media-server:4000', MEDIA_SERVER_AUTH_TOKEN: 'secret') do
      expect { described_class.new(call: call, routing_decision: routing_decision).perform }.to raise_error(Whatsapp::MediaServerClient::SessionError)
    end

    call.reload
    expect(call.status).to eq('failed')
    expect(call.meta['ai_voice']).to include(
      'state' => 'failed',
      'runtime_transport' => 'whatsapp_cloud',
      'call_ref' => "whatsapp:#{call.provider_call_id}"
    )
    expect(call.conversation.additional_attributes).to include('call_status' => 'ai_failed', 'call_direction' => 'inbound')
  end

  it 'fails closed and marks call session failed when Node runtime attach fails after Meta accepted the call' do
    expect(media_client).to receive(:create_session).and_return({ 'session_id' => 'media-ai-3', 'meta_sdp_answer' => 'meta-answer' })
    expect(provider).to receive(:pre_accept_call).with(call.provider_call_id, 'meta-answer').and_return(true)
    expect(provider).to receive(:accept_call).with(call.provider_call_id, 'meta-answer').and_return(true)
    expect(media_client).to receive(:create_runtime_agent).and_return(
      {
        'runtime_session_id' => 'rt-wa-3',
        'stream_url' => 'ws://media-server/sessions/media-ai-3/runtime-stream?token=runtime-token',
        'codec' => 'pcm_s16le',
        'input_sample_rate' => 16_000,
        'output_sample_rate' => 24_000
      }
    )
    expect(runtime_client).to receive(:attach_call).and_raise(Whatsapp::AiVoiceRuntimeClient::AttachError, 'runtime attach failed')
    expect(provider).to receive(:terminate_call).with(call.provider_call_id)
    expect(media_client).to receive(:terminate_session).with('media-ai-3')

    with_modified_env(MEDIA_SERVER_URL: 'http://media-server:4000', MEDIA_SERVER_AUTH_TOKEN: 'secret') do
      expect { described_class.new(call: call, routing_decision: routing_decision).perform }
        .to raise_error(Whatsapp::AiVoiceRuntimeClient::AttachError)
    end

    call.reload
    expect(call.status).to eq('failed')
    call_session = account.telephony_call_sessions.find_by!(external_call_ref: "whatsapp:#{call.provider_call_id}")
    expect(call_session).to have_attributes(
      status: 'failed',
      ended_by: 'system',
      end_reason: 'ai_voice_runtime_attach_failed'
    )
  end
end
