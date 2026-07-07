require 'rails_helper'

RSpec.describe 'Internal Voice AI Tools API', type: :request do
  let(:account) { create(:account) }
  let(:voice_channel) { create(:channel_voice, :sipuni, account: account, phone_number: '+15551230003') }
  let(:voice_inbox) { voice_channel.inbox }
  let(:conversation) { create(:conversation, account: account, inbox: voice_inbox) }
  let(:call_session) do
    create(
      :telephony_call_session,
      account: account,
      conversation: conversation,
      inbox: voice_inbox,
      number_binding: voice_inbox.telephony_number_binding,
      external_call_ref: 'ai-tools-call-1',
      from_number: '+15550001111',
      status: 'in_progress'
    )
  end

  before do
    account.enable_features!('channel_voice')
    Telephony::NumberBinding.sync_from_voice_channel!(voice_channel)
    voice_inbox.telephony_number_binding.routing_policy.update!(
      mode: 'ai',
      ai_deployment_mode: 'onelink_managed',
      onelink_ai_app_ref: 'onelink-ai-voice-app',
      operator_agent_aor: 'sip:voice-operator@example.test'
    )
    call_session
  end

  it 'executes voice-safe find_contact with account scope' do
    contact = create(:contact, account: account, name: 'Caller One', phone_number: '+15550001111')
    create(:contact, name: 'Other Account', phone_number: '+15550001111')

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/tools/find_contact',
           params: { call_ref: call_session.external_call_ref, account_id: account.id, arguments: { phone_number: '+15550001111' } },
           headers: { 'Authorization' => 'Bearer voice-secret' },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('result', 'contacts').pluck('id')).to eq([contact.id])
  end

  it 'creates a private note without sending anything to the caller' do
    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/tools/create_note',
           params: { call_ref: call_session.external_call_ref, account_id: account.id, arguments: { content: 'Caller asked for pricing.' } },
           headers: { 'Authorization' => 'Bearer voice-secret' },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    note = conversation.messages.where(private: true).last
    expect(note.content).to eq('Caller asked for pricing.')
    expect(response.parsed_body.dig('result', 'message_id')).to eq(note.id)
  end

  it 'returns transfer instructions instead of doing a slow Rails-side call bridge operation' do
    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/tools/request_transfer',
           params: { call_ref: call_session.external_call_ref, account_id: account.id, arguments: { reason: 'caller requested operator' } },
           headers: { 'Authorization' => 'Bearer voice-secret' },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['result']).to include(
      'action' => 'transfer',
      'operator_agent_aor' => 'sip:voice-operator@example.test',
      'reason' => 'caller requested operator'
    )
  end

  it 'fails closed for unknown tools' do
    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/tools/delete_everything',
           params: { call_ref: call_session.external_call_ref, account_id: account.id, arguments: {} },
           headers: { 'Authorization' => 'Bearer voice-secret' },
           as: :json
    end

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body['error']).to eq('tool_not_found')
  end

  it 'executes Captain custom tools exposed by the connected inbox assistant' do
    custom_tool = create(
      :captain_custom_tool,
      :with_post,
      account: account,
      title: 'Lookup booking',
      description: 'Find a booking by booking code',
      endpoint_url: 'https://example.com/bookings',
      request_template: '{ "booking_code": "{{ booking_code }}" }',
      response_template: 'Booking status: {{ response.status }}',
      param_schema: [
        { 'name' => 'booking_code', 'type' => 'string', 'description' => 'Booking code', 'required' => true }
      ]
    )
    assistant = create(
      :captain_assistant,
      account: account,
      description: "Use [Lookup booking](tool://#{custom_tool.slug}) when the caller asks about a booking.",
      config: {
        tool_access: {
          agent: {
            enabled: true,
            tool_ids: [custom_tool.slug]
          }
        }
      }
    )
    create(:captain_inbox, captain_assistant: assistant, inbox: voice_inbox)
    stub_request(:post, 'https://example.com/bookings')
      .to_return(status: 200, body: { status: 'confirmed' }.to_json, headers: { 'Content-Type' => 'application/json' })

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post "/internal/voice/ai/tools/#{custom_tool.slug}",
           params: { call_ref: call_session.external_call_ref, account_id: account.id, arguments: { booking_code: 'B-42' } },
           headers: { 'Authorization' => 'Bearer voice-secret' },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('result', 'action')).to eq('captain_tool')
    expect(response.parsed_body.dig('result', 'tool_name')).to eq(custom_tool.slug)
    expect(response.parsed_body.dig('result', 'result')).to eq('Booking status: confirmed')
    expect(WebMock).to have_requested(:post, 'https://example.com/bookings').once
  end

  it 'executes built-in Captain agent tools with adapter-specific execute signatures' do
    assistant = create(
      :captain_assistant,
      account: account,
      description: 'Use [Get conversation](tool://get_conversation) when caller asks about the current conversation.',
      config: {
        tool_access: {
          agent: {
            enabled: true,
            tool_ids: ['get_conversation']
          }
        }
      }
    )
    create(:captain_inbox, captain_assistant: assistant, inbox: voice_inbox)

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/tools/get_conversation',
           params: {
             call_ref: call_session.external_call_ref,
             account_id: account.id,
             arguments: { conversation_id: conversation.display_id }
           },
           headers: { 'Authorization' => 'Bearer voice-secret' },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('result', 'action')).to eq('captain_tool')
    expect(response.parsed_body.dig('result', 'tool_name')).to eq('get_conversation')
    expect(response.parsed_body.dig('result', 'result')).to include("\"display_id\": #{conversation.display_id}")
  end

  it 'does not expose built-in Captain tools that are not selected for the agent' do
    assistant = create(
      :captain_assistant,
      account: account,
      description: 'Answer from the current voice context only.',
      config: {
        tool_access: {
          agent: {
            enabled: true,
            tool_ids: ['faq_lookup']
          }
        }
      }
    )
    create(:captain_inbox, captain_assistant: assistant, inbox: voice_inbox)

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/tools/get_conversation',
           params: {
             call_ref: call_session.external_call_ref,
             account_id: account.id,
             arguments: { conversation_id: conversation.display_id }
           },
           headers: { 'Authorization' => 'Bearer voice-secret' },
           as: :json
    end

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body['error']).to eq('tool_not_found')
  end

  it 'runs faq_lookup through a realtime lexical fast path for voice calls' do
    assistant = create(
      :captain_assistant,
      account: account,
      config: {
        tool_access: {
          agent: {
            enabled: true,
            tool_ids: ['faq_lookup']
          }
        }
      }
    )
    create(:captain_inbox, captain_assistant: assistant, inbox: voice_inbox)
    document = create(:captain_document, account: account, assistant: assistant)
    document_chunk = document.document_chunks.create!(
      account: account,
      assistant: assistant,
      chunk_index: 0,
      content: 'Refund source says refunds are available in 14 days.'
    )
    allow(Captain::DocumentChunk).to receive(:search)

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/tools/faq_lookup',
           params: {
             call_ref: call_session.external_call_ref,
             account_id: account.id,
             arguments: { query: 'refund' }
           },
           headers: { 'Authorization' => 'Bearer voice-secret' },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    result = JSON.parse(response.parsed_body.dig('result', 'result'))
    expect(Captain::DocumentChunk).not_to have_received(:search)
    expect(result).to include('lookup_strategy' => 'lexical_voice_realtime', 'total_count' => 1)
    expect(result['matches'].first).to include(
      'type' => 'document_chunk',
      'answer' => 'Refund source says refunds are available in 14 days.',
      'document_id' => document.id,
      'document_chunk_id' => document_chunk.id
    )
    expect(result['retrieval_trace']).to include(
      'strategy' => 'lexical_voice_realtime',
      'degraded' => true,
      'semantic_attempted' => false,
      'fallback_reason' => 'voice_realtime_fast_path',
      'document_chunk_ids' => [document_chunk.id]
    )
  end

  it 'uses approved FAQ responses in the realtime lexical path' do
    assistant = create(
      :captain_assistant,
      account: account,
      config: {
        tool_access: {
          agent: {
            enabled: true,
            tool_ids: ['faq_lookup']
          }
        }
      }
    )
    create(:captain_inbox, captain_assistant: assistant, inbox: voice_inbox)
    create(:captain_assistant_response, assistant: assistant, account: account, question: 'Refund?', answer: 'Refund in 14 days', status: 'approved')
    allow(Captain::DocumentChunk).to receive(:search)

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/tools/faq_lookup',
           params: {
             call_ref: call_session.external_call_ref,
             account_id: account.id,
             arguments: { query: 'refund' }
           },
           headers: { 'Authorization' => 'Bearer voice-secret' },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    result = JSON.parse(response.parsed_body.dig('result', 'result'))
    expect(Captain::DocumentChunk).not_to have_received(:search)
    expect(result).to include('lookup_strategy' => 'lexical_voice_realtime', 'total_count' => 1)
    expect(result['matches'].first).to include('answer' => 'Refund in 14 days')
    expect(result['retrieval_trace']).to include(
      'strategy' => 'lexical_voice_realtime',
      'degraded' => true,
      'semantic_attempted' => false,
      'fallback_reason' => 'voice_realtime_fast_path',
      'match_count' => 1
    )
  end

  it 'scopes tool writes by account_id when call_ref collides across accounts' do
    other_account = create(:account)
    other_voice_channel = create(:channel_voice, :sipuni, account: other_account, phone_number: '+1555889003')
    Telephony::NumberBinding.sync_from_voice_channel!(other_voice_channel)
    other_conversation = create(:conversation, account: other_account, inbox: other_voice_channel.inbox)
    create(
      :telephony_call_session,
      account: other_account,
      conversation: other_conversation,
      inbox: other_voice_channel.inbox,
      number_binding: other_voice_channel.inbox.telephony_number_binding,
      external_call_ref: 'shared-tools-call-ref',
      status: 'in_progress'
    )
    target_conversation = create(:conversation, account: account, inbox: voice_inbox)
    create(
      :telephony_call_session,
      account: account,
      conversation: target_conversation,
      inbox: voice_inbox,
      number_binding: voice_inbox.telephony_number_binding,
      external_call_ref: 'shared-tools-call-ref',
      status: 'in_progress'
    )

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/tools/create_note',
           params: { call_ref: 'shared-tools-call-ref', account_id: account.id, arguments: { content: 'Tenant scoped note.' } },
           headers: { 'Authorization' => 'Bearer voice-secret' },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(target_conversation.messages.where(private: true).last.content).to eq('Tenant scoped note.')
    expect(other_conversation.messages).not_to exist
  end

  it 'does not run account tools when account_id is valid but call_ref is unresolved in that account' do
    other_account = create(:account)
    create(:telephony_call_session, account: other_account, external_call_ref: 'foreign-tools-call-ref', status: 'in_progress')

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/tools/create_contact',
           params: { call_ref: 'foreign-tools-call-ref', account_id: account.id,
                     arguments: { phone_number: '+155****2222', name: 'Should Not Exist' } },
           headers: { 'Authorization' => 'Bearer voice-secret' },
           as: :json
    end

    expect(response).to have_http_status(:not_found)
    expect(account.contacts.find_by(phone_number: '+155****2222')).to be_nil
  end
end
