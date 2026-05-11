require 'rails_helper'

RSpec.describe 'Internal Voice AI Control API', type: :request do
  let(:account) { create(:account) }
  let(:voice_channel) { create(:channel_voice, :fonoster, account: account, phone_number: '+15550000004') }
  let(:voice_inbox) { voice_channel.inbox }
  let(:conversation) { create(:conversation, account: account, inbox: voice_inbox) }
  let(:call_session) do
    create(
      :telephony_call_session,
      account: account,
      conversation: conversation,
      inbox: voice_inbox,
      number_binding: voice_inbox.telephony_number_binding,
      external_call_ref: 'ai-control-call-1',
      status: 'in_progress'
    )
  end

  before do
    account.enable_features!('channel_voice')
    Telephony::NumberBinding.sync_from_voice_channel!(voice_channel)
    call_session
  end

  it 'records bounded control events in call metadata' do
    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/control',
           params: { call_ref: call_session.external_call_ref, account_id: account.id, action: 'caller_interrupted',
                     metadata: { provider: 'gemini-live' } },
           headers: { 'Authorization' => 'Bearer voice-secret' },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(call_session.reload.metadata.dig('ai_voice', 'control_events').last).to include(
      'action' => 'caller_interrupted',
      'metadata' => { 'provider' => 'gemini-live' }
    )
  end

  it 'accepts explicit AI voice terminal lifecycle reasons' do
    %w[caller_hangup media_stream_closed provider_stream_closed provider_error fonoster_call_closed runtime_closed].each do |action|
      with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
        post '/internal/voice/ai/control',
             params: { call_ref: call_session.external_call_ref, account_id: account.id, action: action,
                       metadata: { reason: action } },
             headers: { 'Authorization' => 'Bearer voice-secret' },
             as: :json
      end

      expect(response).to have_http_status(:ok)
    end

    expect(call_session.reload.metadata.dig('ai_voice', 'control_events').last(6).pluck('action')).to eq(
      %w[caller_hangup media_stream_closed provider_stream_closed provider_error fonoster_call_closed runtime_closed]
    )
  end

  it 'renders AI pickup lifecycle events with the product label' do
    %w[ai_ringing ai_answered].each do |action|
      with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
        post '/internal/voice/ai/control',
             params: { call_ref: call_session.external_call_ref, account_id: account.id, action: action },
             headers: { 'Authorization' => 'Bearer voice-secret' },
             as: :json
      end

      expect(response).to have_http_status(:ok)
    end

    event_messages = conversation.messages.where('source_id LIKE ?', "ai_voice_event:#{call_session.external_call_ref}:ai_%").order(:id)

    expect(event_messages.pluck(:content)).to eq(['AI-принимает звонок', 'AI-принимает звонок'])
  end

  it 'scopes control mutations by account_id when call_ref collides across accounts' do
    other_account = create(:account)
    other_session = create(:telephony_call_session, account: other_account, external_call_ref: 'shared-control-call-ref', status: 'in_progress')
    target_session = create(:telephony_call_session, account: account, external_call_ref: 'shared-control-call-ref', status: 'in_progress')

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/control',
           params: { call_ref: 'shared-control-call-ref', account_id: account.id, action: 'caller_interrupted' },
           headers: { 'Authorization' => 'Bearer voice-secret' },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(target_session.reload.metadata.dig('ai_voice', 'control_events').last['action']).to eq('caller_interrupted')
    expect(other_session.reload.metadata.dig('ai_voice', 'control_events')).to be_blank
  end

  it 'does not fall back to unscoped lookup when account_id is invalid' do
    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/control',
           params: { call_ref: call_session.external_call_ref, account_id: -1, action: 'caller_interrupted' },
           headers: { 'Authorization' => 'Bearer voice-secret' },
           as: :json
    end

    expect(response).to have_http_status(:not_found)
    expect(call_session.reload.metadata.dig('ai_voice', 'control_events')).to be_blank
  end

  it 'does not mutate a call session through an unscoped call_ref' do
    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/control',
           params: { call_ref: call_session.external_call_ref, action: 'caller_interrupted' },
           headers: { 'Authorization' => 'Bearer voice-secret' },
           as: :json
    end

    expect(response).to have_http_status(:not_found)
    expect(call_session.reload.metadata.dig('ai_voice', 'control_events')).to be_blank
  end
end
