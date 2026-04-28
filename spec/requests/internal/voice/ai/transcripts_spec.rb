require 'rails_helper'

RSpec.describe 'Internal Voice AI Transcript API', type: :request do
  let(:account) { create(:account) }
  let(:voice_channel) { create(:channel_voice, :fonoster, account: account, phone_number: '+15551230002') }
  let(:voice_inbox) { voice_channel.inbox }
  let(:conversation) { create(:conversation, account: account, inbox: voice_inbox) }
  let(:call_session) do
    create(
      :telephony_call_session,
      account: account,
      conversation: conversation,
      inbox: voice_inbox,
      number_binding: voice_inbox.telephony_number_binding,
      external_call_ref: 'ai-transcript-call-1',
      status: 'in_progress'
    )
  end

  before do
    account.enable_features!('channel_voice')
    Telephony::NumberBinding.sync_from_voice_channel!(voice_channel)
    call_session
  end

  it 'batches partial transcript without creating chat noise' do
    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/transcript',
           params: {
             call_ref: call_session.external_call_ref,
             account_id: account.id,
             items: [
               { speaker: 'caller', text: 'алло', final: false, at: Time.current.iso8601 }
             ]
           },
           headers: { 'Authorization' => 'Bearer voice-secret' },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('accepted' => 1, 'final_count' => 0, 'partial_count' => 1)
    expect(conversation.messages.where(source_id: "ai_voice_transcript:#{call_session.external_call_ref}")).not_to exist
    expect(call_session.reload.metadata.dig('ai_voice', 'transcript', 'partial_items').last['text']).to eq('алло')
  end

  it 'persists final transcript idempotently as a private conversation note and call metadata' do
    payload = {
      call_ref: call_session.external_call_ref,
      account_id: account.id,
      final: true,
      items: [
        { speaker: 'caller', text: 'Здравствуйте', final: true, at: Time.current.iso8601 },
        { speaker: 'ai', text: 'Здравствуйте, чем могу помочь?', final: true, at: Time.current.iso8601 }
      ]
    }

    2.times do
      with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
        post '/internal/voice/ai/transcript',
             params: payload,
             headers: { 'Authorization' => 'Bearer voice-secret' },
             as: :json
      end
      expect(response).to have_http_status(:ok)
    end

    transcript_messages = conversation.messages.where(source_id: "ai_voice_transcript:#{call_session.external_call_ref}")
    expect(transcript_messages.count).to eq(1)
    expect(transcript_messages.first).to be_private
    expect(transcript_messages.first.content).to include('caller: Здравствуйте', 'ai: Здравствуйте, чем могу помочь?')
    expect(call_session.reload.transcript_ref).to eq("ai_voice_transcript:#{call_session.external_call_ref}")
    expect(call_session.metadata.dig('ai_voice', 'transcript', 'final_items').pluck('text')).to include('Здравствуйте')
  end

  it 'scopes transcript writes by account_id when call_ref collides across accounts' do
    other_account = create(:account)
    other_voice_channel = create(:channel_voice, :fonoster, account: other_account, phone_number: '+1555889002')
    Telephony::NumberBinding.sync_from_voice_channel!(other_voice_channel)
    other_conversation = create(:conversation, account: other_account, inbox: other_voice_channel.inbox)
    other_session = create(
      :telephony_call_session,
      account: other_account,
      conversation: other_conversation,
      inbox: other_voice_channel.inbox,
      number_binding: other_voice_channel.inbox.telephony_number_binding,
      external_call_ref: 'shared-transcript-call-ref',
      status: 'in_progress'
    )
    target_conversation = create(:conversation, account: account, inbox: voice_inbox)
    target_session = create(
      :telephony_call_session,
      account: account,
      conversation: target_conversation,
      inbox: voice_inbox,
      number_binding: voice_inbox.telephony_number_binding,
      external_call_ref: 'shared-transcript-call-ref',
      status: 'in_progress'
    )

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/transcript',
           params: {
             call_ref: 'shared-transcript-call-ref',
             account_id: account.id,
             final: true,
             items: [{ speaker: 'caller', text: 'Tenant scoped transcript', final: true, at: Time.current.iso8601 }]
           },
           headers: { 'Authorization' => 'Bearer voice-secret' },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(target_session.reload.metadata.dig('ai_voice', 'transcript', 'final_items').pluck('text')).to include('Tenant scoped transcript')
    expect(other_session.reload.metadata.dig('ai_voice', 'transcript')).to be_blank
    expect(target_conversation.messages.where(source_id: 'ai_voice_transcript:shared-transcript-call-ref')).to exist
    expect(other_conversation.messages.where(source_id: 'ai_voice_transcript:shared-transcript-call-ref')).not_to exist
  end

  it 'does not write transcript metadata through an unscoped call_ref' do
    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/transcript',
           params: {
             call_ref: call_session.external_call_ref,
             items: [{ speaker: 'caller', text: 'Unscoped transcript', final: true, at: Time.current.iso8601 }]
           },
           headers: { 'Authorization' => 'Bearer voice-secret' },
           as: :json
    end

    expect(response).to have_http_status(:not_found)
    expect(call_session.reload.metadata.dig('ai_voice', 'transcript')).to be_blank
  end
end
