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

  it 'normalizes structured Captain JSON from voice AI into spoken text and reasoning trace' do
    now = Time.current
    voice_message = create(
      :message,
      account: account,
      conversation: conversation,
      inbox: voice_inbox,
      content_type: :voice_call,
      message_type: :incoming,
      content: 'Voice Call',
      source_id: "voice_call:#{call_session.external_call_ref}",
      content_attributes: { data: { call_sid: call_session.external_call_ref, status: 'in_progress' } }
    )
    captain_json_text = {
      reasoning: 'Greeting the caller before asking how to help.',
      response: 'Здравствуйте! Чем могу помочь?',
      artifact_ids: ['internal-doc-1'],
      handoff_reason: 'internal only'
    }.to_json

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/transcript',
           params: {
             call_ref: call_session.external_call_ref,
             account_id: account.id,
             final: true,
             items: [{ speaker: 'ai', text: captain_json_text, final: true, at: now.iso8601 }]
           },
           headers: { 'Authorization' => 'Bearer voice-secret' },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    ai_message = conversation.messages.find_by!(source_id: "ai_voice_turn:#{call_session.external_call_ref}:0:ai")
    expect(ai_message.content).to eq('Здравствуйте! Чем могу помочь?')
    expect(ai_message.content_attributes.dig('data', 'items').first).to include('text' => 'Здравствуйте! Чем могу помочь?')
    expect(ai_message.content_attributes.dig('data', 'items').first).not_to have_key('raw_text')
    expect(ai_message.content_attributes.dig('data', 'items').first).not_to have_key('reasoning')
    expect(ai_message.additional_attributes.dig('captain_trace', 'reasoning')).to eq('Greeting the caller before asking how to help.')

    voice_data = voice_message.reload.content_attributes['data']
    expect(voice_data['transcript']).to eq('ИИ: Здравствуйте! Чем могу помочь?')
    expect(voice_data['transcript_items'].first).to include('text' => 'Здравствуйте! Чем могу помочь?')
    expect(voice_data['transcript_items'].first).not_to have_key('raw_text')
    expect(voice_data['transcript_items'].first).not_to have_key('reasoning')

    stored_item = call_session.reload.metadata.dig('ai_voice', 'transcript', 'final_items').first
    expect(stored_item).to include(
      'text' => 'Здравствуйте! Чем могу помочь?',
      'raw_text' => captain_json_text,
      'reasoning' => 'Greeting the caller before asking how to help.',
      'normalized_from' => 'captain_json_response'
    )
  end

  it 'keeps sidecar-normalized AI metadata out of presentation while preserving trace storage' do
    raw_text = { reasoning: 'Internal trace.', response: 'Добрый день!' }.to_json

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/transcript',
           params: {
             call_ref: call_session.external_call_ref,
             account_id: account.id,
             final: true,
             items: [
               {
                 speaker: 'ai',
                 text: 'Добрый день!',
                 final: true,
                 raw_text: raw_text,
                 reasoning: 'Internal trace.',
                 normalized_from: 'captain_json_response'
               }
             ]
           },
           headers: { 'Authorization' => 'Bearer voice-secret' },
           as: :json
    end

    ai_message = conversation.messages.find_by!(source_id: "ai_voice_turn:#{call_session.external_call_ref}:0:ai")
    expect(ai_message.content).to eq('Добрый день!')
    expect(ai_message.content_attributes.dig('data', 'items').first).not_to have_key('reasoning')
    expect(ai_message.additional_attributes.dig('captain_trace', 'reasoning')).to eq('Internal trace.')
    final_item = call_session.reload.metadata.dig('ai_voice', 'transcript', 'final_items').first
    expect(final_item).to include('raw_text' => raw_text, 'reasoning' => 'Internal trace.')
  end

  it 'attaches tool trace only to the latest AI transcript turn while preserving per-turn reasoning' do
    call_session.update!(
      metadata: {
        'ai_voice' => {
          'control_events' => [
            {
              'action' => 'tool_completed',
              'metadata' => {
                'tool_name' => 'faq_lookup',
                'tool_call_id' => 'tool-turn-1',
                'output' => { 'answer' => 'Found' }
              },
              'sequence' => 1,
              'at' => Time.current.iso8601
            }
          ]
        }
      }
    )

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/transcript',
           params: {
             call_ref: call_session.external_call_ref,
             account_id: account.id,
             final: true,
             items: [
               { speaker: 'ai', text: { reasoning: 'first', response: 'Первый ответ' }.to_json, final: true },
               { speaker: 'caller', text: 'А дальше?', final: true },
               { speaker: 'ai', text: { reasoning: 'second', response: 'Второй ответ' }.to_json, final: true }
             ]
           },
           headers: { 'Authorization' => 'Bearer voice-secret' },
           as: :json
    end

    first_ai = conversation.messages.find_by!(source_id: "ai_voice_turn:#{call_session.external_call_ref}:0:ai")
    second_ai = conversation.messages.find_by!(source_id: "ai_voice_turn:#{call_session.external_call_ref}:2:ai")

    expect(first_ai.additional_attributes.dig('captain_trace', 'reasoning')).to eq('first')
    expect(first_ai.additional_attributes.dig('captain_trace', 'tool_steps')).to be_blank
    expect(second_ai.additional_attributes.dig('captain_trace', 'reasoning')).to eq('second')
    expect(second_ai.additional_attributes.dig('captain_trace', 'tool_steps').first).to include(
      'tool_name' => 'faq_lookup',
      'event' => 'finish'
    )
  end

  it 'persists final transcript as native conversation messages and keeps the voice call summary in sync' do
    now = Time.current
    voice_message = create(
      :message,
      account: account,
      conversation: conversation,
      inbox: voice_inbox,
      content_type: :voice_call,
      message_type: :incoming,
      content: 'Voice Call',
      content_attributes: { data: { call_sid: call_session.external_call_ref, status: 'in_progress' } }
    )
    legacy_public_turn = create(
      :message,
      account: account,
      conversation: conversation,
      inbox: voice_inbox,
      message_type: :outgoing,
      content_type: :text,
      private: false,
      source_id: "ai_voice_turn:#{call_session.external_call_ref}:0",
      content: 'legacy public voice transcript',
      content_attributes: { data: { type: 'ai_voice_transcript_turn' } }
    )
    payload = {
      call_ref: call_session.external_call_ref,
      account_id: account.id,
      final: true,
      items: [
        { speaker: 'caller', text: 'Здравствуйте', final: true, at: now.iso8601 },
        { speaker: 'ai', text: 'Здравствуйте, чем', final: true, at: (now + 1.second).iso8601 },
        { speaker: 'ai', text: 'могу помочь?', final: true, at: (now + 2.seconds).iso8601 },
        { speaker: 'caller', text: 'Нужен оператор', final: true, at: (now + 3.seconds).iso8601 }
      ]
    }

    assistant = create(:captain_assistant, account: account, config: { 'feature_memory' => true })
    create(:captain_inbox, inbox: voice_inbox, captain_assistant: assistant)
    conversation.pending!
    allow(SendReplyJob).to receive(:perform_later)
    allow(Captain::Conversation::ResponseBuilderJob).to receive(:perform_later)

    2.times do
      with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
        post '/internal/voice/ai/transcript',
             params: payload,
             headers: { 'Authorization' => 'Bearer voice-secret' },
             as: :json
      end
      expect(response).to have_http_status(:ok)
    end

    expect(SendReplyJob).not_to have_received(:perform_later)
    expect(Captain::Conversation::ResponseBuilderJob).not_to have_received(:perform_later)
    expect(conversation.messages.where(source_id: "ai_voice_transcript:#{call_session.external_call_ref}")).not_to exist
    expect(Message.exists?(legacy_public_turn.id)).to be(false)

    timeline_messages = conversation.messages.where('source_id LIKE ?', "ai_voice_turn:#{call_session.external_call_ref}:%").order(:created_at, :id)
    expect(timeline_messages.map(&:message_type)).to eq(%w[incoming outgoing incoming])
    expect(timeline_messages.map(&:content)).to eq(['Здравствуйте', 'Здравствуйте, чем могу помочь?', 'Нужен оператор'])
    expect(timeline_messages.second.sender_type).to eq('Captain::Assistant')
    expect(timeline_messages.second.sender_id).to eq(assistant.id)
    expect(timeline_messages.second.content_attributes.dig('data', 'speaker')).to eq('ai')

    data = voice_message.reload.content_attributes['data']
    expect(data['transcript_ref']).to eq("ai_voice_transcript:#{call_session.external_call_ref}")
    expect(data['transcript']).to eq("Клиент: Здравствуйте\nИИ: Здравствуйте, чем могу помочь?\nКлиент: Нужен оператор")
    expect(data['transcript_items'].pluck('text')).to include('Здравствуйте', 'могу помочь?', 'Нужен оператор')
    expect(data.dig('ai_voice', 'transcript_updated_at')).to be_present
    expect(data.dig('ai_voice', 'timeline_messages_enabled')).to be(true)
    expect(call_session.reload.transcript_ref).to eq("ai_voice_transcript:#{call_session.external_call_ref}")
    expect(call_session.metadata.dig('ai_voice', 'transcript', 'final_items').pluck('text')).to include('Здравствуйте')
  end

  it 'updates the exact voice call bubble instead of a newer legacy voice_call bubble' do
    exact_voice_message = create(
      :message,
      account: account,
      conversation: conversation,
      inbox: voice_inbox,
      content_type: :voice_call,
      message_type: :incoming,
      content: 'Voice Call',
      source_id: "voice_call:#{call_session.external_call_ref}",
      content_attributes: { data: { call_sid: call_session.external_call_ref, status: 'in_progress' } }
    )
    legacy_voice_message = create(
      :message,
      account: account,
      conversation: conversation,
      inbox: voice_inbox,
      content_type: :voice_call,
      message_type: :incoming,
      content: 'Legacy Voice Call',
      content_attributes: { data: { status: 'completed' } }
    )

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/transcript',
           params: {
             call_ref: call_session.external_call_ref,
             account_id: account.id,
             final: true,
             items: [{ speaker: 'caller', text: 'Exact bubble transcript', final: true, at: Time.current.iso8601 }]
           },
           headers: { 'Authorization' => 'Bearer voice-secret' },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(exact_voice_message.reload.content_attributes.dig('data', 'transcript_ref')).to eq("ai_voice_transcript:#{call_session.external_call_ref}")
    expect(exact_voice_message.content_attributes.dig('data', 'transcript')).to eq('Клиент: Exact bubble transcript')
    expect(legacy_voice_message.reload.content_attributes.dig('data', 'transcript_ref')).to be_blank
    expect(legacy_voice_message.content_attributes.dig('data', 'transcript')).to be_blank
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
    scoped_turns = target_conversation.messages.where('source_id LIKE ?', 'ai_voice_turn:shared-transcript-call-ref:%')
    expect(scoped_turns.pluck(:content)).to eq(['Tenant scoped transcript'])
    expect(target_conversation.messages.where(source_id: 'ai_voice_transcript:shared-transcript-call-ref')).not_to exist
    expect(other_conversation.messages.where('source_id LIKE ?', 'ai_voice_turn:shared-transcript-call-ref:%')).not_to exist
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
