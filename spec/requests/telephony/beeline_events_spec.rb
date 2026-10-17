# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Telephony::BeelineEvents', type: :request do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:webhook_token) { 'beeline-test-webhook-token-12345' }
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
        'number_ref' => 'num-beeline-req-1',
        'provider_connection_id' => connection.id,
        'routing_mode' => 'operator',
        'display_phone_number' => '+77761234567',
        'ingress_number' => '+77761234567',
        'beeline_events_webhook_token' => webhook_token
      }
    )
  end
  let!(:inbox) do
    create(:inbox, account: account, channel: voice_channel, name: 'Beeline Voice')
  end
  let!(:number_binding) do
    Telephony::NumberBinding.sync_from_voice_channel!(voice_channel.reload)
  end

  describe 'POST /beeline/events/:token' do
    it 'rejects requests with an invalid token' do
      post '/beeline/events/wrong-token', params: { callId: '123' }, as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'responds 200 OK to GET verification pings from Beeline Cloud PBX' do
      get "/beeline/events/#{webhook_token}"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include('ok' => true, 'status' => 'verified')
    end

    it 'creates a missed call, conversation, voice message, and waiting_for_callback when all operators are offline (Xsi-Events XML)' do
      xsi_xml = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <xsi:Event xmlns:xsi="http://schema.broadsoft.com/xsi-events" xmlns:xsi1="http://www.w3.org/2001/XMLSchema-instance" xsi1:type="xsi:SubscriptionEvent">
          <xsi:eventID>evt-offline-missed-1</xsi:eventID>
          <xsi:sequenceNumber>1</xsi:sequenceNumber>
          <xsi:targetId>SIP_001@vpbx-company.cloudpbx.beeline.kz</xsi:targetId>
          <xsi:eventData xsi1:type="xsi:CallReleasedEvent">
            <xsi:call>
              <xsi:callId>callhalf-offline-1:0</xsi:callId>
              <xsi:extTrackingId>track-offline-1</xsi:extTrackingId>
              <xsi:personality>Terminator</xsi:personality>
              <xsi:state>Released</xsi:state>
              <xsi:releasingParty>remoteRelease</xsi:releasingParty>
              <xsi:remoteParty>
                <xsi:name>Клиент Офлайн</xsi:name>
                <xsi:address countryCode="7">tel:+77019998877</xsi:address>
                <xsi:callType>Network</xsi:callType>
              </xsi:remoteParty>
              <xsi:endpoint xsi1:type="xsi:AccessEndpoint">
                <xsi:addressOfRecord>SIP_001@vpbx-company.cloudpbx.beeline.kz</xsi:addressOfRecord>
              </xsi:endpoint>
              <xsi:startTime>1713350000000</xsi:startTime>
              <xsi:releaseTime>1713350020000</xsi:releaseTime>
            </xsi:call>
          </xsi:eventData>
        </xsi:Event>
      XML

      perform_enqueued_jobs only: Telephony::InboundRouteLifecycleJob do
        post "/beeline/events/#{webhook_token}",
             params: xsi_xml,
             headers: { 'CONTENT_TYPE' => 'application/xml' }
      end

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        'ok' => true,
        'correlated' => false,
        'terminal_fallback' => true,
        'call_ref' => 'beeline:track-offline-1',
        'status' => 'missed'
      )

      call_session = account.telephony_call_sessions.find_by(external_call_ref: 'beeline:track-offline-1')
      expect(call_session).to be_present
      expect(call_session.status).to eq('missed')
      expect(call_session.direction).to eq('inbound')
      expect(call_session.from_number).to eq('+77019998877')
      expect(call_session.conversation).to be_present

      conversation = call_session.conversation.reload
      expect(conversation.inbox_id).to eq(inbox.id)
      expect(conversation.contact.phone_number).to eq('+77019998877')
      expect(conversation.additional_attributes['waiting_for_callback']).to eq(true)

      voice_message = conversation.messages.voice_calls.last
      expect(voice_message).to be_present
      expect(voice_message.content_attributes.dig('data', 'status')).to eq('missed')
      expect(voice_message.content_attributes.dig('data', 'waiting_for_callback')).to eq(true)
    end

    it 'correlates with an existing browser webphone session without creating a duplicate CallSession' do
      started = Time.current - 20.seconds
      browser_session = account.telephony_call_sessions.create!(
        inbox: inbox,
        number_binding: number_binding,
        provider: 'beeline',
        direction: 'inbound',
        status: 'in_progress',
        external_call_ref: 'beeline:janus:101:online-call-1',
        from_number: '+77019998877',
        to_number: '+77761234567',
        started_at: started,
        answered_at: started + 5.seconds,
        metadata: { 'sip_username' => 'SIP_001', 'source' => 'browser_janus_sip' }
      )

      xsi_xml = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <xsi:Event xmlns:xsi="http://schema.broadsoft.com/xsi-events" xmlns:xsi1="http://www.w3.org/2001/XMLSchema-instance">
          <xsi:eventID>evt-online-release-1</xsi:eventID>
          <xsi:eventData xsi1:type="xsi:CallReleasedEvent">
            <xsi:call>
              <xsi:callId>callhalf-online-1:0</xsi:callId>
              <xsi:extTrackingId>track-online-1</xsi:extTrackingId>
              <xsi:personality>Terminator</xsi:personality>
              <xsi:state>Released</xsi:state>
              <xsi:remoteParty>
                <xsi:address>tel:+77019998877</xsi:address>
              </xsi:remoteParty>
              <xsi:endpoint xsi1:type="xsi:AccessEndpoint">
                <xsi:addressOfRecord>SIP_001@vpbx-company.cloudpbx.beeline.kz</xsi:addressOfRecord>
              </xsi:endpoint>
              <xsi:startTime>#{(started.to_f * 1000).to_i}</xsi:startTime>
              <xsi:answerTime>#{((started + 5.seconds).to_f * 1000).to_i}</xsi:answerTime>
              <xsi:releaseTime>#{((started + 35.seconds).to_f * 1000).to_i}</xsi:releaseTime>
            </xsi:call>
          </xsi:eventData>
        </xsi:Event>
      XML

      expect do
        post "/beeline/events/#{webhook_token}",
             params: xsi_xml,
             headers: { 'CONTENT_TYPE' => 'application/xml' }
      end.not_to change(Telephony::CallSession, :count)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        'ok' => true,
        'correlated' => true,
        'call_ref' => browser_session.external_call_ref,
        'status' => 'completed'
      )
      expect(browser_session.reload.status).to eq('completed')
      expect(browser_session.duration_seconds).to eq(30)
    end

    it 'closes all ringing sibling legs in a multi-operator group as missed and sets waiting_for_callback' do
      started = Time.current - 15.seconds
      contact = create(:contact, account: account, phone_number: '+77019998877')
      contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox, source_id: '+77019998877')
      conversation = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)

      leg1 = account.telephony_call_sessions.create!(
        inbox: inbox,
        number_binding: number_binding,
        conversation: conversation,
        contact: contact,
        provider: 'beeline',
        direction: 'inbound',
        status: 'ringing',
        external_call_ref: 'beeline:janus:101:group-missed-1',
        from_number: '+77019998877',
        to_number: '+77761234567',
        started_at: started,
        metadata: {
          'logical_call_key' => 'group-missed-key-1',
          'logical_call_group_ref' => 'beeline:janus:101:group-missed-1',
          'metadata' => { 'sip_username' => 'SIP_001@vpbx-company.cloudpbx.beeline.kz', 'operator_extension' => '101' }
        }
      )
      leg2 = account.telephony_call_sessions.create!(
        inbox: inbox,
        number_binding: number_binding,
        conversation: conversation,
        contact: contact,
        provider: 'beeline',
        direction: 'inbound',
        status: 'ringing',
        external_call_ref: 'beeline:janus:102:group-missed-1',
        from_number: '+77019998877',
        to_number: '+77761234567',
        started_at: started + 1.second,
        metadata: {
          'logical_call_key' => 'group-missed-key-1',
          'logical_call_group_ref' => 'beeline:janus:101:group-missed-1',
          'metadata' => { 'sip_username' => 'SIP_002@vpbx-company.cloudpbx.beeline.kz', 'operator_extension' => '102' }
        }
      )

      xsi_xml = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <xsi:Event xmlns:xsi="http://schema.broadsoft.com/xsi-events" xmlns:xsi1="http://www.w3.org/2001/XMLSchema-instance">
          <xsi:eventID>evt-group-missed-1</xsi:eventID>
          <xsi:eventData xsi1:type="xsi:CallReleasedEvent">
            <xsi:call>
              <xsi:callId>callhalf-group-1:0</xsi:callId>
              <xsi:extTrackingId>track-group-missed-1</xsi:extTrackingId>
              <xsi:personality>Terminator</xsi:personality>
              <xsi:state>Released</xsi:state>
              <xsi:remoteParty>
                <xsi:address>tel:+77019998877</xsi:address>
              </xsi:remoteParty>
              <xsi:endpoint xsi1:type="xsi:AccessEndpoint">
                <xsi:addressOfRecord>SIP_001@vpbx-company.cloudpbx.beeline.kz</xsi:addressOfRecord>
              </xsi:endpoint>
              <xsi:startTime>#{(started.to_f * 1000).to_i}</xsi:startTime>
              <xsi:releaseTime>#{((started + 15.seconds).to_f * 1000).to_i}</xsi:releaseTime>
            </xsi:call>
          </xsi:eventData>
        </xsi:Event>
      XML

      post "/beeline/events/#{webhook_token}",
           params: xsi_xml,
           headers: { 'CONTENT_TYPE' => 'application/xml' }

      expect(response).to have_http_status(:ok)
      expect(leg1.reload.status).to eq('missed')
      expect(leg2.reload.status).to eq('missed')
      expect(conversation.reload.additional_attributes['waiting_for_callback']).to eq(true)
    end

    it 'routes CallReleasedEvent to the winning sibling leg when the initially linked leg was closed as answered_by_other_operator' do
      started = Time.current - 30.seconds
      leg1 = account.telephony_call_sessions.create!(
        inbox: inbox,
        number_binding: number_binding,
        provider: 'beeline',
        direction: 'inbound',
        status: 'no_answer',
        external_call_ref: 'beeline:janus:101:winner-test-1',
        provider_call_sid: 'track-winner-1',
        from_number: '+77019998877',
        to_number: '+77761234567',
        started_at: started,
        ended_at: started + 4.seconds,
        metadata: {
          'logical_call_key' => 'winner-group-key-1',
          'logical_call_group_ref' => 'beeline:janus:101:winner-test-1',
          'beeline_ext_tracking_id' => 'track-winner-1',
          'end_reason' => 'answered_by_other_operator'
        }
      )
      leg2 = account.telephony_call_sessions.create!(
        inbox: inbox,
        number_binding: number_binding,
        provider: 'beeline',
        direction: 'inbound',
        status: 'in_progress',
        external_call_ref: 'beeline:janus:102:winner-test-1',
        from_number: '+77019998877',
        to_number: '+77761234567',
        started_at: started,
        answered_at: started + 4.seconds,
        metadata: {
          'logical_call_key' => 'winner-group-key-1',
          'logical_call_group_ref' => 'beeline:janus:101:winner-test-1',
          'metadata' => { 'sip_username' => 'SIP_002@vpbx-company.cloudpbx.beeline.kz' }
        }
      )

      xsi_xml = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <xsi:Event xmlns:xsi="http://schema.broadsoft.com/xsi-events" xmlns:xsi1="http://www.w3.org/2001/XMLSchema-instance">
          <xsi:eventID>evt-winner-release-1</xsi:eventID>
          <xsi:eventData xsi1:type="xsi:CallReleasedEvent">
            <xsi:call>
              <xsi:callId>callhalf-winner-2:0</xsi:callId>
              <xsi:extTrackingId>track-winner-1</xsi:extTrackingId>
              <xsi:personality>Terminator</xsi:personality>
              <xsi:state>Released</xsi:state>
              <xsi:remoteParty>
                <xsi:address>tel:+77019998877</xsi:address>
              </xsi:remoteParty>
              <xsi:startTime>#{(started.to_f * 1000).to_i}</xsi:startTime>
              <xsi:answerTime>#{((started + 4.seconds).to_f * 1000).to_i}</xsi:answerTime>
              <xsi:releaseTime>#{((started + 29.seconds).to_f * 1000).to_i}</xsi:releaseTime>
            </xsi:call>
          </xsi:eventData>
        </xsi:Event>
      XML

      post "/beeline/events/#{webhook_token}",
           params: xsi_xml,
           headers: { 'CONTENT_TYPE' => 'application/xml' }

      expect(response).to have_http_status(:ok)
      expect(leg1.reload.status).to eq('no_answer')
      expect(leg2.reload.status).to eq('completed')
      expect(leg2.duration_seconds).to eq(25)
    end

    it 'responds 200 OK to empty POST body verification pings and non-call heartbeat XML on both routes' do
      post "/telephony/beeline/events/#{webhook_token}", params: '', headers: { 'CONTENT_TYPE' => 'text/plain' }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include('ok' => true, 'status' => 'verified')

      heartbeat_xml = <<~XML
        <xsi:Event xmlns:xsi="http://schema.broadsoft.com/xsi-events" xmlns:xsi1="http://www.w3.org/2001/XMLSchema-instance">
          <xsi:eventID>evt-hb-1</xsi:eventID>
          <xsi:eventData xsi1:type="xsi:SubscriptionTerminatedEvent"/>
        </xsi:Event>
      XML

      post "/beeline/events/#{webhook_token}", params: heartbeat_xml, headers: { 'CONTENT_TYPE' => 'application/xml' }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include('ok' => true, 'ignored' => true)
    end
  end
end
