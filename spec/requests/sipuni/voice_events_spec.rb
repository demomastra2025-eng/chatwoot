# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Sipuni voice events' do
  let(:account) { create(:account) }
  let(:voice_channel) { create(:channel_voice, :sipuni, account: account, phone_number: '+77271234567') }
  let(:inbox) { voice_channel.inbox }
  let(:token) { voice_channel.provider_config.with_indifferent_access[:webhook_token] }
  let(:path) { "/webhooks/sipuni/voice/#{inbox.id}" }

  it 'accepts a valid Sipuni webhook and persists the native voice call timeline' do
    params = {
      token: token,
      event: '2',
      status: 'ANSWER',
      call_id: 'sipuni-webhook-call-1',
      src_num: '77011234567',
      dst_num: '77271234567',
      timestamp: '1717171760',
      call_start_timestamp: '1717171700',
      call_answer_timestamp: '1717171710',
      call_record_link: 'https://sipuni.example.test/recordings/call-1.mp3'
    }

    expect do
      post path, params: params
    end.to change(Telephony::CallSession, :count).by(1)

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body).to include('success' => true, 'call_ref' => 'sipuni-webhook-call-1')

    call_session = account.telephony_call_sessions.find_by!(external_call_ref: 'sipuni-webhook-call-1')
    expect(call_session).to have_attributes(
      provider: 'sipuni',
      status: 'completed',
      direction: 'inbound',
      from_number: '+77011234567',
      to_number: '+77271234567',
      duration_seconds: 50,
      recording_ref: 'https://sipuni.example.test/recordings/call-1.mp3'
    )

    voice_message = call_session.conversation.messages.voice_calls.find_by!(source_id: 'voice_call:sipuni-webhook-call-1')
    expect(voice_message.content_attributes.dig('data', 'status')).to eq('completed')
    expect(voice_message.content_attributes.dig('data', 'recording_url')).to eq('https://sipuni.example.test/recordings/call-1.mp3')
    expect(call_session.events.last.payload.to_json).not_to include(token)
  end

  it 'creates a native outgoing voice timeline for outbound Sipuni softphone events' do
    operator = create(:user, account: account, role: :agent)
    agent_binding = create(
      :telephony_agent_binding,
      account: account,
      user: operator,
      provider: 'sipuni',
      agent_ref: 'sipuni-agent-100',
      agent_aor: 'sip:100@sipuni.example'
    )
    allow(SendReplyJob).to receive(:perform_later).and_return(true)

    params = {
      token: token,
      event: '2',
      status: 'ANSWER',
      call_id: 'sipuni-webhook-outbound-1',
      src_num: '100',
      short_src_num: '100',
      dst_num: '77015550102',
      src_type: '2',
      dst_type: '1',
      timestamp: '1717171760',
      call_start_timestamp: '1717171700',
      call_answer_timestamp: '1717171710',
      call_record_link: 'https://sipuni.example.test/recordings/outbound-1.mp3'
    }

    expect do
      post path, params: params
    end.to change(Telephony::CallSession, :count).by(1)

    expect(response).to have_http_status(:ok)
    call_session = account.telephony_call_sessions.find_by!(external_call_ref: 'sipuni-webhook-outbound-1')
    expect(call_session).to have_attributes(
      provider: 'sipuni',
      status: 'completed',
      direction: 'outbound',
      from_number: '+77271234567',
      to_number: '+77015550102',
      duration_seconds: 50,
      recording_ref: 'https://sipuni.example.test/recordings/outbound-1.mp3'
    )
    expect(call_session.agent_binding).to eq(agent_binding)

    conversation = call_session.conversation
    expect(conversation).to be_present
    expect(conversation.contact.phone_number).to eq('+77015550102')
    expect(conversation.additional_attributes).to include(
      'call_direction' => 'outbound',
      'call_status' => 'completed',
      'telephony_provider' => 'sipuni'
    )

    voice_message = conversation.messages.voice_calls.find_by!(source_id: 'voice_call:sipuni-webhook-outbound-1')
    expect(voice_message.message_type).to eq('outgoing')
    expect(voice_message.sender).to eq(operator)
    expect(voice_message.content_attributes.dig('data', 'call_direction')).to eq('outbound')
    expect(voice_message.content_attributes.dig('data', 'recording_url')).to eq('https://sipuni.example.test/recordings/outbound-1.mp3')
    expect(SendReplyJob).not_to have_received(:perform_later)
  end

  it 'rejects requests with an invalid webhook token' do
    expect do
      get path, params: {
        token: 'invalid-token',
        event: '1',
        call_id: 'sipuni-webhook-call-2',
        src_num: '77011234567',
        dst_num: '77271234567',
        timestamp: '1717171700'
      }
    end.not_to change(Telephony::CallSession, :count)

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to include('success' => false)
  end
end
