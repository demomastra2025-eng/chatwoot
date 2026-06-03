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
        call_record_link: 'https://sipuni.com/api/crm/record?id=call-2&hash=recording-hash&user=056124'
      }
    ).perform

    expect(payload).to include(
      event: 'session_completed',
      status: 'completed',
      duration: 50,
      recording_ref: 'https://sipuni.com/api/crm/record?id=call-2&hash=recording-hash&user=056124',
      recording_url: 'https://sipuni.com/api/crm/record?id=call-2&hash=recording-hash&user=056124'
    )
    expect(payload[:metadata]).to include(
      provider: 'sipuni',
      status: 'ANSWER',
      recording_link_present: true
    )
  end

  it 'does not expose a non-answered call record link as a playable recording' do
    payload = described_class.new(
      inbox: inbox,
      params: {
        event: '2',
        status: 'NOANSWER',
        call_id: 'sipuni-call-no-answer',
        src_num: '77011234567',
        dst_num: '77271234567',
        timestamp: '1717171760',
        call_start_timestamp: '1717171700',
        call_record_link: 'https://sipuni.com/api/crm/record?id=no-answer&hash=recording-hash&user=056124'
      }
    ).perform

    expect(payload).to include(
      event: 'dial_status',
      status: 'no_answer',
      duration: 0
    )
    expect(payload).not_to have_key(:recording_ref)
    expect(payload).not_to have_key(:recording_url)
    expect(payload[:metadata]).to include(recording_link_present: true)
  end

  it 'preserves raw Sipuni webhook fields without authentication tokens' do
    payload = described_class.new(
      inbox: inbox,
      params: {
        token: 'webhook-token',
        webhook_token: 'alternate-webhook-token',
        call_record_link: 'https://sipuni.com/api/crm/record?id=raw-call&hash=secret-hash&user=056124',
        callRecordLink: 'https://sipuni.com/api/crm/record?id=raw-call-2&hash=secret-hash-2&user=056124',
        recording_url: 'https://sipuni.com/api/crm/record?id=raw-call-3&hash=secret-hash-3&user=056124',
        recordingUrl: 'https://sipuni.com/api/crm/record?id=raw-call-4&hash=secret-hash-4&user=056124',
        hash: 'secret-hash',
        event: '1',
        call_id: 'sipuni-call-with-raw-metadata',
        src_num: '77011234567',
        dst_num: '77271234567_id356795',
        src_type: '1',
        dst_type: '1',
        timestamp: '1717171700',
        user_id: '056124',
        transfer_from: '',
        last_called: '',
        channel: 'SIP/013997 77003470027-000063a8',
        pbxdstnum: '87271234567',
        treeName: 'Incoming',
        treeNumber: '000-2776321',
        roistat: '0',
        roistat_number: '',
        roistat_market: 'test-market'
      }
    ).perform

    expect(payload[:metadata]).to include(
      sipuni_user_id: '056124',
      provider_channel: 'SIP/013997 77003470027-000063a8',
      pbx_destination_number: '87271234567',
      roistat: '0',
      roistat_market: 'test-market',
      tree_name: 'Incoming',
      tree_number: '000-2776321'
    )
    expect(payload[:metadata][:raw_webhook]).to include(
      'call_id' => 'sipuni-call-with-raw-metadata',
      'transfer_from' => '',
      'last_called' => '',
      'roistat_number' => ''
    )
    filtered_keys = %w[token webhook_token call_record_link callRecordLink recording_url recordingUrl hash]
    expect(payload[:metadata][:raw_webhook].keys).not_to include(*filtered_keys)
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

  it 'maps Sipuni terminal statuses without exposing non-answer recordings' do
    {
      'BUSY' => %w[dial_status busy callee],
      'NOANSWER' => %w[dial_status no_answer callee],
      'NO_ANSWER' => %w[dial_status no_answer callee],
      'CANCEL' => %w[dial_status cancelled caller],
      'CANCELLED' => %w[dial_status cancelled caller],
      'CONGESTION' => %w[provider_error failed provider],
      'CHANUNAVAIL' => %w[provider_error failed provider]
    }.each do |sipuni_status, (event_name, normalized_status, ended_by)|
      payload = described_class.new(
        inbox: inbox,
        params: {
          event: '2',
          status: sipuni_status,
          call_id: "sipuni-call-#{sipuni_status.downcase}",
          src_num: '77011234567',
          dst_num: '77271234567',
          timestamp: '1717171760',
          call_start_timestamp: '1717171700',
          call_record_link: "https://sipuni.com/api/crm/record?id=#{sipuni_status.downcase}&hash=recording-hash&user=056124"
        }
      ).perform

      expect(payload).to include(
        event: event_name,
        status: normalized_status,
        duration: 0,
        ended_by: ended_by,
        end_reason: sipuni_status.downcase
      )
      expect(payload).not_to have_key(:recording_ref)
      expect(payload).not_to have_key(:recording_url)
    end
  end

  it 'ignores Sipuni recording links outside Sipuni HTTPS hosts' do
    unsafe_url = 'https://attacker.example.test/recordings/call.mp3?hash=secret'

    payload = described_class.new(
      inbox: inbox,
      params: {
        event: '2',
        status: 'ANSWER',
        call_id: 'sipuni-call-unsafe-recording',
        src_num: '77011234567',
        dst_num: '77271234567',
        timestamp: '1717171760',
        call_start_timestamp: '1717171700',
        call_answer_timestamp: '1717171710',
        call_record_link: unsafe_url
      }
    ).perform

    expect(payload).to include(event: 'session_completed', status: 'completed')
    expect(payload).not_to have_key(:recording_ref)
    expect(payload).not_to have_key(:recording_url)
    expect(payload[:metadata]).to include(recording_link_present: true)
    expect(payload[:metadata][:raw_webhook].to_json).not_to include(unsafe_url)
  end
end
