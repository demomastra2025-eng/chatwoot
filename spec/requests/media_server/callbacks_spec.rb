require 'rails_helper'

RSpec.describe 'Media server callbacks', type: :request do
  let(:account) { create(:account) }
  let(:call) { create(:call, account: account, status: 'in_progress', media_session_id: 'session-1') }
  let(:headers) { { 'Authorization' => 'Bearer secret' } }
  let(:provider) { double('provider', terminate_call: true) }

  before do
    Current.suppress_runtime_events = true
    Conversation.skip_callback(:create, :before, :determine_conversation_status)
    Conversation.skip_callback(:commit, :after, :notify_conversation_creation)
    allow_any_instance_of(Channel::Whatsapp).to receive(:provider_service).and_return(provider)
  end

  after do
    Conversation.set_callback(:commit, :after, :notify_conversation_creation, on: :create)
    Conversation.set_callback(:create, :before, :determine_conversation_status)
    Current.suppress_runtime_events = nil
  end

  describe 'authentication' do
    it 'rejects missing shared token even when callback payload is otherwise valid' do
      with_modified_env(MEDIA_SERVER_AUTH_TOKEN: 'secret') do
        post '/callbacks/media_server/agent_disconnected',
             params: { session_id: call.media_session_id, account_id: account.id, call_id: call.provider_call_id },
             as: :json
      end

      expect(response).to have_http_status(:unauthorized)
    end

    it 'fails closed when the server auth token is not configured' do
      with_modified_env(MEDIA_SERVER_AUTH_TOKEN: nil) do
        post '/callbacks/media_server/agent_disconnected',
             params: { session_id: call.media_session_id, account_id: account.id, call_id: call.provider_call_id },
             headers: headers,
             as: :json
      end

      expect(response).to have_http_status(:unauthorized)
    end
  end

  it 'requires account_id so account-scoped cable filtering can deliver the event' do
    with_modified_env(MEDIA_SERVER_AUTH_TOKEN: 'secret') do
      post '/callbacks/media_server/agent_disconnected',
           params: { session_id: call.media_session_id, call_id: call.provider_call_id },
           headers: headers,
           as: :json
    end

    expect(response).to have_http_status(:bad_request)
  end

  it 'broadcasts agent disconnect events with account_id and conversation_id' do
    expect(ActionCable.server).to receive(:broadcast).with(
      "account_#{account.id}",
      hash_including(
        event: 'whatsapp_call.agent_disconnected',
        data: hash_including(
          account_id: account.id,
          id: call.id,
          call_id: call.provider_call_id,
          conversation_id: call.conversation_id,
          reason: 'disconnected'
        )
      )
    )

    with_modified_env(MEDIA_SERVER_AUTH_TOKEN: 'secret') do
      post '/callbacks/media_server/agent_disconnected',
           params: { session_id: call.media_session_id, account_id: account.id, call_id: call.provider_call_id, reason: 'disconnected' },
           headers: headers,
           as: :json
    end

    expect(response).to have_http_status(:ok)
  end

  it 'enqueues recording fetch once for duplicate recording_ready callbacks' do
    expect(Whatsapp::CallRecordingFetchJob).to receive(:perform_later).with(call.id).once

    with_modified_env(MEDIA_SERVER_AUTH_TOKEN: 'secret') do
      2.times do
        post '/callbacks/media_server/recording_ready',
             params: { session_id: call.media_session_id, account_id: account.id, call_id: call.provider_call_id, file_size_bytes: 123 },
             headers: headers,
             as: :json
        expect(response).to have_http_status(:ok)
      end
    end

    callbacks = call.reload.meta.dig('media_server', 'callbacks')
    expect(callbacks['recording_ready_at']).to be_present
    expect(callbacks['recording_file_size_bytes']).to eq(123)
  end

  it 'processes session termination idempotently and avoids duplicate provider/cable side effects' do
    expect(provider).to receive(:terminate_call).with(call.provider_call_id).once.and_return(true)
    expect(ActionCable.server).to receive(:broadcast).once.with(
      "account_#{account.id}",
      hash_including(
        event: 'whatsapp_call.ended',
        data: hash_including(account_id: account.id, call_id: call.provider_call_id, status: 'completed')
      )
    )

    with_modified_env(MEDIA_SERVER_AUTH_TOKEN: 'secret') do
      2.times do
        post '/callbacks/media_server/session_terminated',
             params: { session_id: call.media_session_id, account_id: account.id, call_id: call.provider_call_id, reason: 'agent_terminated',
                       duration_seconds: 7 },
             headers: headers,
             as: :json
        expect(response).to have_http_status(:ok)
      end
    end

    expect(call.reload.status).to eq('completed')
    expect(call.duration_seconds).to eq(7)
    expect(call.conversation.reload.additional_attributes['call_status']).to eq('completed')
  end
end
