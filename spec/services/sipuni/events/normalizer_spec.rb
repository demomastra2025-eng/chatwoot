# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Sipuni::Events::Normalizer do
  let(:account) { create(:account) }
  let(:voice_channel) { create(:channel_voice, :sipuni, account: account, phone_number: '+77271234567') }
  let(:inbox) { voice_channel.inbox }

  it 'normalizes inbound start events into telephony payloads' do
    payload = described_class.new(
      inbox: inbox,
      params: {
        event: '1',
        call_id: 'sipuni-call-1',
        src_num: '77011234567',
        dst_num: '77271234567',
        src_type: '1',
        dst_type: '1',
        timestamp: '1717171700'
      }
    ).perform

    expect(payload).to include(
      provider: 'sipuni',
      event: 'session_started',
      call_ref: 'sipuni-call-1',
      direction: 'inbound',
      from_number: '+77011234567',
      to_number: '+77271234567',
      ingress_number: '+77271234567',
      account_id: account.id,
      inbox_id: inbox.id
    )
    expect(payload[:event_key]).to include('sipuni')
  end

  it 'normalizes answered terminal events with duration and recording url' do
    payload = described_class.new(
      inbox: inbox,
      params: {
        event: '2',
        status: 'ANSWER',
        call_id: 'sipuni-call-2',
        src_num: '77011234567',
        dst_num: '77271234567',
        timestamp: '1717171760',
        call_start_timestamp: '1717171700',
        call_answer_timestamp: '1717171710',
        call_record_link: 'https://sipuni.example.test/recordings/call-2.mp3'
      }
    ).perform

    expect(payload).to include(
      event: 'session_completed',
      status: 'completed',
      duration: 50,
      recording_ref: 'https://sipuni.example.test/recordings/call-2.mp3',
      recording_url: 'https://sipuni.example.test/recordings/call-2.mp3'
    )
    expect(payload[:metadata]).to include(
      provider: 'sipuni',
      status: 'ANSWER',
      recording_link_present: true
    )
  end

  it 'detects outbound calls from an internal Sipuni extension to an external number' do
    operator = create(:user, account: account, role: :agent)
    agent_binding = create(
      :telephony_agent_binding,
      account: account,
      user: operator,
      provider: 'sipuni',
      agent_ref: 'sipuni-agent-100',
      agent_aor: 'sip:100@sipuni.example'
    )

    payload = described_class.new(
      inbox: inbox,
      params: {
        event: '1',
        call_id: 'sipuni-call-3',
        src_num: '100',
        short_src_num: '100',
        dst_num: '77015550102',
        src_type: '2',
        dst_type: '1',
        timestamp: '1717171700'
      }
    ).perform

    expect(payload).to include(
      event: 'session_started',
      direction: 'outbound',
      from_number: '+77271234567',
      to_number: '+77015550102',
      agent_ref: agent_binding.agent_ref,
      chatwoot_user_id: operator.id
    )
    expect(payload[:metadata]).to include(
      operator_internal_number: '100',
      agent_ref: agent_binding.agent_ref,
      chatwoot_user_id: operator.id
    )
  end
end
