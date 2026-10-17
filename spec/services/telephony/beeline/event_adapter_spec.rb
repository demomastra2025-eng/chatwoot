# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telephony::Beeline::EventAdapter do
  let(:account) { create(:account) }
  let(:connection) do
    create(:telephony_provider_connection, account: account, provider_kind: 'beeline', status: 'active')
  end
  let(:voice_channel) do
    Channel::Voice.create!(
      account: account,
      provider: 'beeline',
      phone_number: '+77761234567',
      provider_config: {
        'provider_kind' => 'beeline',
        'number_ref' => 'num-beeline-1',
        'provider_connection_id' => connection.id,
        'routing_mode' => 'operator',
        'display_phone_number' => '+77761234567',
        'ingress_number' => '+77761234567',
        'beeline_events_webhook_token' => 'secret-beeline-token'
      }
    )
  end
  let(:inbox) do
    create(:inbox, account: account, channel: voice_channel, name: 'Beeline Cloud PBX')
  end
  let!(:number_binding) do
    Telephony::NumberBinding.sync_from_voice_channel!(voice_channel.reload)
  end

  describe '#call with BroadWorks Xsi-Events XML' do
    it 'parses an inbound CallReceivedEvent XML as ringing' do
      xml = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <xsi:Event xmlns:xsi="http://schema.broadsoft.com/xsi-events" xmlns:xsi1="http://www.w3.org/2001/XMLSchema-instance" xsi1:type="xsi:SubscriptionEvent">
          <xsi:eventID>evt-001</xsi:eventID>
          <xsi:sequenceNumber>1</xsi:sequenceNumber>
          <xsi:targetId>SIP_001@vpbx-company.cloudpbx.beeline.kz</xsi:targetId>
          <xsi:eventData xsi1:type="xsi:CallReceivedEvent">
            <xsi:call>
              <xsi:callId>callhalf-9001:0</xsi:callId>
              <xsi:extTrackingId>track-9001</xsi:extTrackingId>
              <xsi:personality>Terminator</xsi:personality>
              <xsi:state>Alerting</xsi:state>
              <xsi:remoteParty>
                <xsi:name>Алия Клиент</xsi:name>
                <xsi:address countryCode="7">tel:+77015554433</xsi:address>
                <xsi:callType>Network</xsi:callType>
              </xsi:remoteParty>
              <xsi:endpoint xsi1:type="xsi:AccessEndpoint">
                <xsi:addressOfRecord>SIP_001@vpbx-company.cloudpbx.beeline.kz</xsi:addressOfRecord>
              </xsi:endpoint>
              <xsi:startTime>1713350000000</xsi:startTime>
            </xsi:call>
          </xsi:eventData>
        </xsi:Event>
      XML

      adapter = described_class.new(params: {}, inbox: inbox, raw_body: xml)
      payload = adapter.call

      expect(payload).to be_present
      expect(payload['provider']).to eq('beeline')
      expect(payload['direction']).to eq('inbound')
      expect(payload['event']).to eq('ringing')
      expect(payload['status']).to eq('ringing')
      expect(payload['call_ref']).to eq('beeline:track-9001')
      expect(payload['from']).to eq('+77015554433')
      expect(payload['to']).to eq('+77761234567')
      expect(payload.dig('metadata', 'beeline_ext_tracking_id')).to eq('track-9001')
      expect(payload.dig('metadata', 'abonent_extension')).to eq('SIP_001')
      expect(adapter.correlation_status).to eq(:unmatched)
    end

    it 'parses an unanswered inbound CallReleasedEvent XML as missed' do
      xml = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <xsi:Event xmlns:xsi="http://schema.broadsoft.com/xsi-events" xmlns:xsi1="http://www.w3.org/2001/XMLSchema-instance" xsi1:type="xsi:SubscriptionEvent">
          <xsi:eventID>evt-002</xsi:eventID>
          <xsi:sequenceNumber>2</xsi:sequenceNumber>
          <xsi:targetId>SIP_001@vpbx-company.cloudpbx.beeline.kz</xsi:targetId>
          <xsi:eventData xsi1:type="xsi:CallReleasedEvent">
            <xsi:call>
              <xsi:callId>callhalf-9002:0</xsi:callId>
              <xsi:extTrackingId>track-9002</xsi:extTrackingId>
              <xsi:personality>Terminator</xsi:personality>
              <xsi:state>Released</xsi:state>
              <xsi:releasingParty>remoteRelease</xsi:releasingParty>
              <xsi:remoteParty>
                <xsi:address>tel:87015554433</xsi:address>
              </xsi:remoteParty>
              <xsi:startTime>1713350000000</xsi:startTime>
              <xsi:releaseTime>1713350025000</xsi:releaseTime>
            </xsi:call>
          </xsi:eventData>
        </xsi:Event>
      XML

      adapter = described_class.new(params: {}, inbox: inbox, raw_body: xml)
      payload = adapter.call

      expect(payload).to be_present
      expect(payload['event']).to eq('missed')
      expect(payload['status']).to eq('missed')
      expect(payload['direction']).to eq('inbound')
      expect(payload['from']).to eq('+77015554433')
      expect(payload['answered_at']).to be_nil
      expect(payload['ended_at']).to be_present
    end

    it 'parses an answered CallReleasedEvent XML with answerTime as completed with duration' do
      xml = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <xsi:Event xmlns:xsi="http://schema.broadsoft.com/xsi-events" xmlns:xsi1="http://www.w3.org/2001/XMLSchema-instance">
          <xsi:eventID>evt-003</xsi:eventID>
          <xsi:eventData xsi1:type="xsi:CallReleasedEvent">
            <xsi:call>
              <xsi:callId>callhalf-9003:0</xsi:callId>
              <xsi:extTrackingId>track-9003</xsi:extTrackingId>
              <xsi:personality>Terminator</xsi:personality>
              <xsi:state>Released</xsi:state>
              <xsi:remoteParty>
                <xsi:address>tel:+77015554433</xsi:address>
              </xsi:remoteParty>
              <xsi:startTime>1713350000000</xsi:startTime>
              <xsi:answerTime>1713350005000</xsi:answerTime>
              <xsi:releaseTime>1713350050000</xsi:releaseTime>
            </xsi:call>
          </xsi:eventData>
        </xsi:Event>
      XML

      payload = described_class.new(params: {}, inbox: inbox, raw_body: xml).call

      expect(payload['event']).to eq('completed')
      expect(payload['status']).to eq('completed')
      expect(payload['duration']).to eq(45)
      expect(payload['answered_at']).to be_present
    end

    it 'ignores unanswered sibling hunt-group leg release when another leg already answered' do
      answered_xml = <<~XML
        <xsi:Event xmlns:xsi="http://schema.broadsoft.com/xsi-events" xmlns:xsi1="http://www.w3.org/2001/XMLSchema-instance">
          <xsi:eventID>evt-hunt-1</xsi:eventID>
          <xsi:eventData xsi1:type="xsi:CallAnsweredEvent">
            <xsi:call>
              <xsi:callId>callhalf-op1:0</xsi:callId>
              <xsi:extTrackingId>track-hunt-1</xsi:extTrackingId>
              <xsi:personality>Terminator</xsi:personality>
              <xsi:state>Active</xsi:state>
              <xsi:remoteParty><xsi:address>tel:+77015554433</xsi:address></xsi:remoteParty>
              <xsi:startTime>1713350000000</xsi:startTime>
              <xsi:answerTime>1713350004000</xsi:answerTime>
            </xsi:call>
          </xsi:eventData>
        </xsi:Event>
      XML

      sibling_release_xml = <<~XML
        <xsi:Event xmlns:xsi="http://schema.broadsoft.com/xsi-events" xmlns:xsi1="http://www.w3.org/2001/XMLSchema-instance">
          <xsi:eventID>evt-hunt-2</xsi:eventID>
          <xsi:eventData xsi1:type="xsi:CallReleasedEvent">
            <xsi:call>
              <xsi:callId>callhalf-op2:0</xsi:callId>
              <xsi:extTrackingId>track-hunt-1</xsi:extTrackingId>
              <xsi:personality>Terminator</xsi:personality>
              <xsi:state>Released</xsi:state>
              <xsi:remoteParty><xsi:address>tel:+77015554433</xsi:address></xsi:remoteParty>
              <xsi:startTime>1713350000000</xsi:startTime>
              <xsi:releaseTime>1713350004100</xsi:releaseTime>
            </xsi:call>
          </xsi:eventData>
        </xsi:Event>
      XML

      first_payload = described_class.new(params: {}, inbox: inbox, raw_body: answered_xml).call
      expect(first_payload['status']).to eq('in_progress')

      sibling_payload = described_class.new(params: {}, inbox: inbox, raw_body: sibling_release_xml).call
      expect(sibling_payload).to be_nil

      completed_session = account.telephony_call_sessions.create!(
        inbox: inbox,
        number_binding: number_binding,
        provider: 'beeline',
        direction: 'inbound',
        status: 'completed',
        external_call_ref: 'beeline:janus:101:hunt-completed',
        provider_call_sid: 'track-hunt-1',
        from_number: '+77015554433',
        to_number: '+77761234567',
        started_at: Time.at(1_713_350_000),
        answered_at: Time.at(1_713_350_004),
        ended_at: Time.at(1_713_350_034),
        duration_seconds: 30,
        metadata: { 'beeline_ext_tracking_id' => 'track-hunt-1' }
      )
      late_sibling_payload = described_class.new(params: {}, inbox: inbox, raw_body: sibling_release_xml).call
      expect(late_sibling_payload).to be_nil
      expect(completed_session.reload.duration_seconds).to eq(30)
    end

    it 'returns nil for non-call subscription heartbeat XML' do
      xml = <<~XML
        <xsi:Event xmlns:xsi="http://schema.broadsoft.com/xsi-events" xmlns:xsi1="http://www.w3.org/2001/XMLSchema-instance">
          <xsi:eventID>evt-sub-1</xsi:eventID>
          <xsi:eventData xsi1:type="xsi:SubscriptionTerminatedEvent"/>
        </xsi:Event>
      XML

      expect(described_class.new(params: {}, inbox: inbox, raw_body: xml).call).to be_nil
    end
  end

  describe '#call with JSON payloads and browser WebRTC correlation' do
    it 'correlates with an active browser webphone session including multi-operator sibling legs' do
      started = Time.current - 15.seconds
      leg1 = account.telephony_call_sessions.create!(
        inbox: inbox,
        number_binding: number_binding,
        provider: 'beeline',
        direction: 'inbound',
        status: 'ringing',
        external_call_ref: 'beeline:janus:101:call-abc',
        from_number: '+77015554433',
        to_number: '+77761234567',
        started_at: started,
        metadata: { 'sip_username' => 'SIP_001', 'logical_call_root_ref' => 'beeline:janus:101:call-abc' }
      )
      account.telephony_call_sessions.create!(
        inbox: inbox,
        number_binding: number_binding,
        provider: 'beeline',
        direction: 'inbound',
        status: 'ringing',
        external_call_ref: 'beeline:janus:102:call-abc',
        from_number: '+77015554433',
        to_number: '+77761234567',
        started_at: started + 1.second,
        metadata: { 'sip_username' => 'SIP_002', 'logical_call_root_ref' => 'beeline:janus:101:call-abc' }
      )

      adapter = described_class.new(
        params: {
          'callId' => 'beeline-json-1',
          'direction' => 'INBOUND',
          'status' => 'MISSED',
          'phone' => '87015554433',
          'startDate' => (started.to_f * 1000).to_i
        },
        inbox: inbox
      )
      payload = adapter.call

      expect(adapter.correlation_status).to eq(:matched)
      expect(adapter.correlated_session).to eq(leg1)
      expect(payload['call_ref']).to eq(leg1.external_call_ref)
      expect(payload['status']).to eq('missed')
    end

    it 'returns nil safely for empty or malformed XML and empty JSON payloads' do
      expect(described_class.new(params: {}, inbox: inbox, raw_body: '').call).to be_nil
      expect(described_class.new(params: {}, inbox: inbox, raw_body: '<xsi:Event><unclosed').call).to be_nil
    end

    it 'marks completed outbound CallReleasedEvent with callee_leg_answered' do
      xml = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <xsi:Event xmlns:xsi="http://schema.broadsoft.com/xsi-events" xmlns:xsi1="http://www.w3.org/2001/XMLSchema-instance">
          <xsi:eventID>evt-out-1</xsi:eventID>
          <xsi:eventData xsi1:type="xsi:CallReleasedEvent">
            <xsi:call>
              <xsi:callId>callhalf-out-1:0</xsi:callId>
              <xsi:extTrackingId>track-out-1</xsi:extTrackingId>
              <xsi:personality>Originator</xsi:personality>
              <xsi:state>Released</xsi:state>
              <xsi:remoteParty>
                <xsi:address>tel:+77015554433</xsi:address>
              </xsi:remoteParty>
              <xsi:startTime>1713350000000</xsi:startTime>
              <xsi:answerTime>1713350004000</xsi:answerTime>
              <xsi:releaseTime>1713350034000</xsi:releaseTime>
            </xsi:call>
          </xsi:eventData>
        </xsi:Event>
      XML

      payload = described_class.new(params: {}, inbox: inbox, raw_body: xml).call
      expect(payload['direction']).to eq('outbound')
      expect(payload['status']).to eq('completed')
      expect(payload['callee_leg_answered']).to eq(true)
      expect(payload['duration']).to eq(30)
    end
  end
end
