require 'rails_helper'

RSpec.describe Telephony::CallReconciliationService do
  subject(:service) do
    described_class.new(account: account, bridge_client: bridge_client, now: now, stale_after: 0.seconds)
  end

  let(:account) { create(:account) }
  let(:bridge_client) { instance_double(Telephony::BridgeClient) }
  let(:now) { Time.zone.parse('2026-04-28T12:00:00Z') }

  before do
    allow(bridge_client).to receive(:get).and_return({ 'items' => bridge_items, 'nextPageToken' => '' })
  end

  describe '#perform' do
    let(:bridge_items) { [] }

    it 'finalizes active outbound sessions from bridge terminal statuses' do
      call_session = create(
        :telephony_call_session,
        account: account,
        direction: 'outbound',
        status: 'created',
        external_call_ref: 'call-ref-1',
        provider_call_sid: 'provider-call-1',
        started_at: now - 2.minutes,
        metadata: { 'existing' => true }
      )
      ended_at = '2026-04-28T11:59:40Z'
      bridge_items << {
        'ref' => 'call-ref-1',
        'callId' => 'provider-call-1',
        'status' => 'BUSY',
        'startedAt' => '2026-04-28T11:59:10Z',
        'endedAt' => ended_at,
        'duration' => 0,
        'direction' => 'TO_PSTN'
      }

      result = service.perform

      expect(result).to include(checked: 1, updated: 1, errors: 0)
      expect(call_session.reload).to have_attributes(
        status: 'busy',
        end_reason: 'busy',
        duration_seconds: 0
      )
      expect(call_session.ended_at.iso8601).to eq(Time.zone.parse(ended_at).iso8601)
      expect(call_session.metadata['existing']).to be(true)
      expect(call_session.metadata['bridge_reconciliation']).to include(
        'provider_status' => 'BUSY',
        'provider_direction' => 'TO_PSTN',
        'raw_ref' => 'call-ref-1'
      )
      expect(call_session.legs).to include(
        include(
          'source' => 'bridge_reconciliation',
          'status' => 'busy',
          'provider_status' => 'BUSY'
        )
      )
    end

    it 'does not downgrade an in-progress call when a stale poll reports ringing' do
      call_session = create(
        :telephony_call_session,
        account: account,
        direction: 'outbound',
        status: 'in_progress',
        external_call_ref: 'call-ref-2',
        provider_call_sid: 'provider-call-2',
        answered_at: now - 1.minute,
        started_at: now - 2.minutes
      )
      bridge_items << {
        'ref' => 'call-ref-2',
        'callId' => 'provider-call-2',
        'status' => 'RINGING',
        'startedAt' => '2026-04-28T11:59:00Z'
      }

      result = service.perform

      expect(result).to include(checked: 1, updated: 1, errors: 0)
      expect(call_session.reload.status).to eq('in_progress')
      expect(call_session.metadata['bridge_reconciliation']).to include('provider_status' => 'RINGING')
    end

    it 'unsticks ended UNKNOWN bridge records with a conservative terminal status while preserving raw status' do
      call_session = create(
        :telephony_call_session,
        account: account,
        direction: 'inbound',
        status: 'ringing',
        external_call_ref: 'call-ref-3',
        provider_call_sid: 'provider-call-3',
        started_at: now - 5.minutes
      )
      bridge_items << {
        'ref' => 'call-ref-3',
        'callId' => 'provider-call-3',
        'status' => 'UNKNOWN',
        'startedAt' => '2026-04-28T11:55:00Z',
        'endedAt' => '2026-04-28T11:55:15Z',
        'duration' => 0,
        'direction' => 'FROM_PSTN'
      }

      result = service.perform

      expect(result).to include(checked: 1, updated: 1, errors: 0)
      expect(call_session.reload).to have_attributes(
        status: 'missed',
        end_reason: 'bridge_unknown_terminal'
      )
      expect(call_session.metadata['bridge_reconciliation']).to include(
        'provider_status' => 'UNKNOWN',
        'terminal_fallback' => 'missed'
      )
    end

    it 'does not finalize an answered outbound UNKNOWN bridge record with a zero-duration terminal edge' do
      voice_channel = create(
        :channel_voice,
        :fonoster,
        account: account,
        phone_number: '+77172705175'
      )
      voice_inbox = voice_channel.inbox
      contact = create(:contact, account: account, phone_number: '+77070001002')
      contact_inbox = create(
        :contact_inbox,
        contact: contact,
        inbox: voice_inbox,
        source_id: contact.phone_number
      )
      conversation = create(
        :conversation,
        account: account,
        inbox: voice_inbox,
        contact: contact,
        contact_inbox: contact_inbox
      )
      call_session = create(
        :telephony_call_session,
        account: account,
        conversation: conversation,
        contact: contact,
        inbox: voice_inbox,
        number_binding: nil,
        direction: 'outbound',
        status: 'in_progress',
        external_call_ref: 'call-ref-sync-message',
        from_number: voice_channel.phone_number,
        to_number: contact.phone_number,
        started_at: now - 2.minutes,
        answered_at: now - 90.seconds
      )
      message = conversation.messages.create!(
        account: account,
        inbox: voice_inbox,
        message_type: :outgoing,
        content_type: :voice_call,
        content: 'Voice Call',
        source_id: call_session.voice_call_source_id,
        content_attributes: {
          'data' => {
            'call_sid' => call_session.external_call_ref,
            'status' => 'in_progress',
            'call_direction' => 'outbound'
          }
        }.to_json
      )
      original_content_attributes = message.content_attributes.deep_dup
      bridge_items << {
        'ref' => 'call-ref-sync-message',
        'status' => 'UNKNOWN',
        'startedAt' => (now - 2.minutes).iso8601,
        'endedAt' => call_session.answered_at.iso8601,
        'duration' => 0,
        'direction' => 'TO_PSTN'
      }

      service.perform

      expect(call_session.reload).to have_attributes(
        status: 'in_progress',
        end_reason: nil
      )
      expect(call_session.ended_at).to be_nil
      expect(message.reload.content_attributes).to eq(original_content_attributes)
      expect(call_session.metadata['bridge_reconciliation']).to include(
        'provider_status' => 'UNKNOWN'
      )
      expect(call_session.metadata['bridge_reconciliation']).not_to have_key('target_status')
    end

    it 'finalizes an answered outbound UNKNOWN bridge record when the bridge terminal edge has elapsed duration' do
      call_session = create(
        :telephony_call_session,
        account: account,
        direction: 'outbound',
        status: 'in_progress',
        external_call_ref: 'call-ref-answered-unknown-with-duration',
        started_at: now - 2.minutes,
        answered_at: now - 90.seconds
      )
      bridge_items << {
        'ref' => 'call-ref-answered-unknown-with-duration',
        'status' => 'UNKNOWN',
        'startedAt' => (now - 2.minutes).iso8601,
        'endedAt' => (now - 30.seconds).iso8601,
        'duration' => 0,
        'direction' => 'TO_PSTN'
      }

      service.perform

      expect(call_session.reload).to have_attributes(
        status: 'completed',
        end_reason: 'bridge_unknown_terminal',
        duration_seconds: 60
      )
    end

    it 'does not treat an outbound operator-only answered leg as a completed customer call' do
      call_session = create(
        :telephony_call_session,
        account: account,
        direction: 'outbound',
        status: 'in_progress',
        external_call_ref: 'call-ref-operator-only-outbound',
        started_at: now - 2.minutes,
        answered_at: now - 90.seconds,
        legs: [
          {
            'event_key' => 'evt-operator-answer',
            'event_type' => 'operator_answered',
            'status' => 'in_progress',
            'leg' => 'operator'
          }
        ]
      )
      bridge_items << {
        'ref' => 'call-ref-operator-only-outbound',
        'status' => 'UNKNOWN',
        'startedAt' => (now - 2.minutes).iso8601,
        'endedAt' => (now - 30.seconds).iso8601,
        'duration' => 0,
        'direction' => 'TO_PSTN'
      }

      service.perform

      expect(call_session.reload).to have_attributes(
        status: 'no_answer',
        end_reason: 'bridge_unknown_terminal',
        duration_seconds: 0
      )
    end

    it 'keeps unanswered outbound UNKNOWN bridge records as no-answer' do
      call_session = create(
        :telephony_call_session,
        account: account,
        direction: 'outbound',
        status: 'ringing',
        external_call_ref: 'call-ref-outbound-no-answer',
        started_at: now - 2.minutes
      )
      bridge_items << {
        'ref' => 'call-ref-outbound-no-answer',
        'status' => 'UNKNOWN',
        'startedAt' => (now - 2.minutes).iso8601,
        'endedAt' => (now - 30.seconds).iso8601,
        'duration' => 0,
        'direction' => 'TO_PSTN'
      }

      service.perform

      expect(call_session.reload).to have_attributes(
        status: 'no_answer',
        end_reason: 'bridge_unknown_terminal'
      )
    end

    it 'syncs the conversation and voice bubble when reconciliation finalizes an outbound call' do
      voice_channel = create(:channel_voice, :fonoster, account: account, phone_number: '+77172705175')
      voice_inbox = voice_channel.inbox
      contact = create(:contact, account: account, phone_number: '+77070001002')
      contact_inbox = create(:contact_inbox, contact: contact, inbox: voice_inbox, source_id: contact.phone_number)
      conversation = create(
        :conversation,
        account: account,
        inbox: voice_inbox,
        contact: contact,
        contact_inbox: contact_inbox,
        additional_attributes: {
          'call_status' => 'created',
          'call_direction' => 'outbound',
          'fonoster_call_ref' => 'call-ref-outbound-ui-sync'
        }
      )
      call_session = create(
        :telephony_call_session,
        account: account,
        conversation: conversation,
        contact: contact,
        inbox: voice_inbox,
        number_binding: voice_inbox.telephony_number_binding,
        direction: 'outbound',
        status: 'created',
        external_call_ref: 'call-ref-outbound-ui-sync',
        from_number: voice_channel.phone_number,
        to_number: contact.phone_number,
        started_at: now - 2.minutes
      )
      message = conversation.messages.create!(
        account: account,
        inbox: voice_inbox,
        message_type: :outgoing,
        content_type: :voice_call,
        content: 'Voice Call',
        source_id: call_session.voice_call_source_id,
        content_attributes: {
          'data' => {
            'call_sid' => call_session.external_call_ref,
            'status' => 'created',
            'call_direction' => 'outbound'
          }
        }
      )
      bridge_items << {
        'ref' => 'call-ref-outbound-ui-sync',
        'status' => 'UNKNOWN',
        'startedAt' => (now - 2.minutes).iso8601,
        'endedAt' => (now - 30.seconds).iso8601,
        'duration' => 0,
        'direction' => 'TO_PSTN'
      }

      service.perform

      aggregate_failures do
        expect(call_session.reload).to have_attributes(
          status: 'no_answer',
          end_reason: 'bridge_unknown_terminal'
        )
        expect(message.reload.content_attributes.dig('data', 'status')).to eq(
          'no_answer'
        )
        expect(conversation.reload.additional_attributes).to include(
          'call_status' => 'no_answer',
          'call_direction' => 'outbound',
          'fonoster_call_ref' => call_session.external_call_ref
        )
      end
    end

    it 'closes stale operator calls that disappeared from the bridge poll as no-answer' do
      call_session = create(
        :telephony_call_session,
        account: account,
        direction: 'inbound',
        status: 'ringing',
        external_call_ref: 'call-ref-missing-operator',
        started_at: now - 10.minutes,
        last_event_at: now - 6.minutes,
        metadata: {
          'last_payload' => {
            'metadata' => {
              'route_action' => 'operator',
              'route_reason' => 'operator_route'
            }
          }
        }
      )

      result = service.perform

      expect(result).to include(checked: 1, missing: 1, updated: 1, errors: 0)
      expect(call_session.reload).to have_attributes(
        status: 'no_answer',
        ended_at: now,
        ended_by: 'bridge_reconciliation',
        end_reason: 'bridge_missing_operator_no_answer'
      )
      expect(call_session.metadata['bridge_reconciliation']).to include(
        'missing_from_bridge' => true,
        'route_action' => 'operator',
        'target_status' => 'no_answer'
      )
    end

    it 'fails stale local Sipuni outbound calls that never receive a provider event' do
      provider_connection = create(:telephony_provider_connection, account: account, provider_kind: 'sipuni')
      voice_channel = create(
        :channel_voice,
        account: account,
        provider: 'sipuni',
        phone_number: '+77070001001',
        provider_config: {
          provider_kind: 'sipuni',
          provider_connection_id: provider_connection.id,
          number_ref: 'sipuni-main-line'
        }
      )
      voice_inbox = voice_channel.inbox
      number_binding = Telephony::NumberBinding.sync_from_voice_channel!(voice_channel)
      contact = create(:contact, account: account, phone_number: '+77070001002')
      contact_inbox = create(:contact_inbox, contact: contact, inbox: voice_inbox, source_id: contact.phone_number)
      conversation = create(
        :conversation,
        account: account,
        inbox: voice_inbox,
        contact: contact,
        contact_inbox: contact_inbox,
        additional_attributes: {
          'call_status' => 'created',
          'call_direction' => 'outbound',
          'sipuni_call_ref' => 'sipuni:local:stale-outbound-1'
        }
      )
      call_session = create(
        :telephony_call_session,
        account: account,
        conversation: conversation,
        contact: contact,
        inbox: voice_inbox,
        number_binding: number_binding,
        provider: 'sipuni',
        external_call_ref: 'sipuni:local:stale-outbound-1',
        provider_call_sid: nil,
        status: 'created',
        direction: 'outbound',
        from_number: voice_channel.phone_number,
        to_number: contact.phone_number,
        started_at: now - 2.minutes,
        last_event_at: now - 2.minutes,
        metadata: {
          'sipuni_call_ref' => 'sipuni:local:stale-outbound-1',
          'metadata' => {
            'source' => 'onelink_browser_janus_sip',
            'provider' => 'sipuni',
            'route_action' => 'operator',
            'direction' => 'outbound',
            'call_direction' => 'outbound'
          }
        }
      )
      message = conversation.messages.create!(
        account: account,
        inbox: voice_inbox,
        message_type: :outgoing,
        content_type: :voice_call,
        content: 'Voice Call',
        source_id: call_session.voice_call_source_id,
        content_attributes: {
          'data' => {
            'call_sid' => call_session.external_call_ref,
            'status' => 'created',
            'call_direction' => 'outbound'
          }
        }
      )

      with_modified_env('TELEPHONY_SIPUNI_LOCAL_OUTBOUND_MISSING_AFTER_SECONDS' => '30') do
        result = described_class.new(account: account, bridge_client: bridge_client, now: now, stale_after: 0.seconds).perform

        expect(result).to include(checked: 1, missing: 1, updated: 1, errors: 0)
      end

      aggregate_failures do
        expect(call_session.reload).to have_attributes(
          status: 'failed',
          ended_at: now,
          ended_by: 'sipuni_local_outbound_reconciliation',
          end_reason: 'sipuni_provider_event_missing',
          duration_seconds: 0
        )
        expect(call_session.metadata['sipuni_reconciliation']).to include(
          'local_outbound_missing_provider_event' => true,
          'target_status' => 'failed'
        )
        expect(message.reload.content_attributes.dig('data', 'status')).to eq('failed')
        expect(conversation.reload.additional_attributes).to include(
          'call_status' => 'failed',
          'call_direction' => 'outbound',
          'sipuni_call_ref' => call_session.external_call_ref
        )
      end
    end

    it 'closes stale Sipuni provider inbound ringing calls and syncs the voice bubble' do
      provider_connection = create(:telephony_provider_connection, account: account, provider_kind: 'sipuni')
      voice_channel = create(
        :channel_voice,
        account: account,
        provider: 'sipuni',
        phone_number: '+77070001001',
        provider_config: {
          provider_kind: 'sipuni',
          provider_connection_id: provider_connection.id,
          number_ref: 'sipuni-main-line'
        }
      )
      voice_inbox = voice_channel.inbox
      number_binding = Telephony::NumberBinding.sync_from_voice_channel!(voice_channel)
      contact = create(:contact, account: account, phone_number: '+77070001002')
      contact_inbox = create(:contact_inbox, contact: contact, inbox: voice_inbox, source_id: contact.phone_number)
      conversation = create(
        :conversation,
        account: account,
        inbox: voice_inbox,
        contact: contact,
        contact_inbox: contact_inbox,
        additional_attributes: {
          'call_status' => 'ringing',
          'call_direction' => 'inbound',
          'sipuni_call_ref' => 'sipuni:1782827000.500001'
        }
      )
      call_session = create(
        :telephony_call_session,
        account: account,
        conversation: conversation,
        contact: contact,
        inbox: voice_inbox,
        number_binding: number_binding,
        provider: 'sipuni',
        external_call_ref: 'sipuni:1782827000.500001',
        provider_call_sid: '1782827000.500001',
        status: 'ringing',
        direction: 'inbound',
        from_number: contact.phone_number,
        to_number: voice_channel.phone_number,
        started_at: now - 10.minutes,
        last_event_at: now - 10.minutes,
        metadata: {
          'metadata' => {
            'source' => 'sipuni_http_api',
            'provider' => 'sipuni',
            'route_action' => 'operator',
            'operator_internal_extension' => '502'
          }
        }
      )
      message = conversation.messages.create!(
        account: account,
        inbox: voice_inbox,
        message_type: :incoming,
        content_type: :voice_call,
        content: 'Voice Call',
        source_id: call_session.voice_call_source_id,
        content_attributes: {
          'data' => {
            'call_sid' => call_session.external_call_ref,
            'status' => 'ringing',
            'call_direction' => 'inbound'
          }
        }
      )

      with_modified_env('TELEPHONY_SIPUNI_PROVIDER_RINGING_STALE_AFTER_SECONDS' => '120') do
        result = described_class.new(account: account, bridge_client: bridge_client, now: now, stale_after: 0.seconds).perform

        expect(result).to include(checked: 1, missing: 1, updated: 1, errors: 0)
      end

      aggregate_failures do
        expect(call_session.reload).to have_attributes(
          status: 'no_answer',
          ended_at: now,
          ended_by: 'sipuni_provider_reconciliation',
          end_reason: 'sipuni_provider_missing_operator_no_answer',
          duration_seconds: 0
        )
        expect(call_session.metadata['sipuni_reconciliation']).to include(
          'provider_terminal_missing' => true,
          'provider_call_sid' => '1782827000.500001',
          'target_status' => 'no_answer',
          'previous_status' => 'ringing'
        )
        expect(message.reload.content_attributes.dig('data', 'status')).to eq('no_answer')
        expect(conversation.reload.additional_attributes).to include(
          'call_status' => 'no_answer',
          'call_direction' => 'inbound',
          'sipuni_call_ref' => call_session.external_call_ref
        )
      end
    end

    it 'does not close fresh Sipuni provider in-progress calls' do
      call_session = create(
        :telephony_call_session,
        account: account,
        provider: 'sipuni',
        external_call_ref: 'sipuni:1782827000.500002',
        provider_call_sid: '1782827000.500002',
        status: 'in_progress',
        direction: 'inbound',
        started_at: now - 30.minutes,
        answered_at: now - 29.minutes,
        last_event_at: now - 30.minutes
      )

      with_modified_env('TELEPHONY_SIPUNI_PROVIDER_IN_PROGRESS_STALE_AFTER_SECONDS' => '7200') do
        result = described_class.new(account: account, bridge_client: bridge_client, now: now, stale_after: 0.seconds).perform

        expect(result).to include(checked: 0, missing: 0, updated: 0, errors: 0)
      end

      expect(call_session.reload.status).to eq('in_progress')
    end

    it 'closes very stale Sipuni provider in-progress calls as completed' do
      call_session = create(
        :telephony_call_session,
        account: account,
        provider: 'sipuni',
        external_call_ref: 'sipuni:1782827000.500003',
        provider_call_sid: '1782827000.500003',
        status: 'in_progress',
        direction: 'inbound',
        started_at: now - 5.hours,
        answered_at: now - 4.hours - 30.minutes,
        last_event_at: now - 4.hours - 30.minutes
      )

      with_modified_env('TELEPHONY_SIPUNI_PROVIDER_IN_PROGRESS_STALE_AFTER_SECONDS' => '3600') do
        result = described_class.new(account: account, bridge_client: bridge_client, now: now, stale_after: 0.seconds).perform

        expect(result).to include(checked: 1, missing: 1, updated: 1, errors: 0)
      end

      expect(call_session.reload).to have_attributes(
        status: 'completed',
        ended_at: now,
        ended_by: 'sipuni_provider_reconciliation',
        end_reason: 'sipuni_provider_missing_completed_call',
        duration_seconds: 16_200
      )
    end

    it 'closes stale native Asterisk Janus ringing calls and syncs the voice bubble' do
      provider_connection = create(:telephony_provider_connection, account: account, provider_kind: 'asterisk_analog')
      voice_channel = create(
        :channel_voice,
        account: account,
        provider: 'asterisk_analog',
        phone_number: '+77172705175',
        provider_config: {
          provider_kind: 'asterisk_analog',
          provider_connection_id: provider_connection.id,
          number_ref: 'asterisk-main-line'
        }
      )
      voice_inbox = voice_channel.inbox
      number_binding = Telephony::NumberBinding.sync_from_voice_channel!(voice_channel)
      contact = create(:contact, account: account, phone_number: '+77066318623')
      contact_inbox = create(:contact_inbox, contact: contact, inbox: voice_inbox, source_id: contact.phone_number)
      call_ref = 'asterisk_analog:janus:41:deadbeef@10.77.0.2'
      conversation = create(
        :conversation,
        account: account,
        inbox: voice_inbox,
        contact: contact,
        contact_inbox: contact_inbox,
        additional_attributes: {
          'call_status' => 'ringing',
          'call_direction' => 'inbound',
          'asterisk_analog_call_ref' => call_ref
        }
      )
      call_session = create(
        :telephony_call_session,
        account: account,
        conversation: conversation,
        contact: contact,
        inbox: voice_inbox,
        number_binding: number_binding,
        provider: 'asterisk_analog',
        external_call_ref: call_ref,
        provider_call_sid: nil,
        status: 'ringing',
        direction: 'inbound',
        from_number: contact.phone_number,
        to_number: voice_channel.phone_number,
        started_at: now - 10.minutes,
        last_event_at: now - 10.minutes,
        metadata: {
          'metadata' => {
            'source' => 'onelink_browser_janus_sip',
            'provider' => 'asterisk_analog',
            'route_action' => 'operator',
            'operator_internal_extension' => '9098'
          }
        }
      )
      message = conversation.messages.create!(
        account: account,
        inbox: voice_inbox,
        message_type: :incoming,
        content_type: :voice_call,
        content: 'Voice Call',
        source_id: call_session.voice_call_source_id,
        content_attributes: {
          'data' => {
            'call_sid' => call_session.external_call_ref,
            'status' => 'ringing',
            'call_direction' => 'inbound'
          }
        }
      )

      with_modified_env('TELEPHONY_NATIVE_SIP_PRE_ANSWER_STALE_AFTER_SECONDS' => '120') do
        result = described_class.new(account: account, bridge_client: bridge_client, now: now, stale_after: 0.seconds).perform

        expect(result).to include(checked: 1, missing: 1, updated: 1, errors: 0)
      end

      aggregate_failures do
        expect(call_session.reload).to have_attributes(
          status: 'no_answer',
          ended_at: now,
          ended_by: 'native_sip_reconciliation',
          end_reason: 'native_sip_missing_operator_no_answer',
          duration_seconds: 0
        )
        expect(call_session.metadata['native_sip_reconciliation']).to include(
          'native_terminal_missing' => true,
          'provider' => 'asterisk_analog',
          'target_status' => 'no_answer',
          'previous_status' => 'ringing'
        )
        expect(message.reload.content_attributes.dig('data', 'status')).to eq('no_answer')
        expect(conversation.reload.additional_attributes).to include(
          'call_status' => 'no_answer',
          'call_direction' => 'inbound'
        )
      end
    end

    it 'closes very stale native Binotel Janus in-progress calls as completed' do
      call_session = create(
        :telephony_call_session,
        account: account,
        provider: 'binotel',
        external_call_ref: 'binotel:janus:42:stale-active@pbx.example.test',
        provider_call_sid: nil,
        status: 'in_progress',
        direction: 'outbound',
        started_at: now - 5.hours,
        answered_at: now - 4.hours - 15.minutes,
        last_event_at: now - 4.hours - 15.minutes,
        metadata: {
          'metadata' => {
            'source' => 'onelink_browser_janus_sip',
            'provider' => 'binotel'
          }
        }
      )

      with_modified_env('TELEPHONY_NATIVE_SIP_IN_PROGRESS_STALE_AFTER_SECONDS' => '3600') do
        result = described_class.new(account: account, bridge_client: bridge_client, now: now, stale_after: 0.seconds).perform

        expect(result).to include(checked: 1, missing: 1, updated: 1, errors: 0)
      end

      expect(call_session.reload).to have_attributes(
        status: 'completed',
        ended_at: now,
        ended_by: 'native_sip_reconciliation',
        end_reason: 'native_sip_missing_completed_call',
        duration_seconds: 15_300
      )
    end

    it 'does not close fresh native Janus calls' do
      call_session = create(
        :telephony_call_session,
        account: account,
        provider: 'asterisk_analog',
        external_call_ref: 'asterisk_analog:janus:41:fresh@10.77.0.2',
        provider_call_sid: nil,
        status: 'ringing',
        direction: 'inbound',
        started_at: now - 30.seconds,
        last_event_at: now - 30.seconds,
        metadata: {
          'metadata' => {
            'source' => 'onelink_browser_janus_sip',
            'provider' => 'asterisk_analog',
            'route_action' => 'operator'
          }
        }
      )

      with_modified_env('TELEPHONY_NATIVE_SIP_PRE_ANSWER_STALE_AFTER_SECONDS' => '120') do
        result = described_class.new(account: account, bridge_client: bridge_client, now: now, stale_after: 0.seconds).perform

        expect(result).to include(checked: 0, missing: 0, updated: 0, errors: 0)
      end

      expect(call_session.reload.status).to eq('ringing')
    end

    it 'does not close missing non-operator inbound calls without terminal evidence' do
      call_session = create(
        :telephony_call_session,
        account: account,
        direction: 'inbound',
        status: 'in_progress',
        external_call_ref: 'call-ref-missing-ai',
        started_at: now - 10.minutes,
        last_event_at: now - 6.minutes,
        metadata: {
          'last_payload' => {
            'metadata' => {
              'route_action' => 'ai',
              'route_reason' => 'ai_route'
            }
          }
        }
      )

      result = service.perform

      expect(result).to include(checked: 1, missing: 1, updated: 0, errors: 0)
      expect(call_session.reload.status).to eq('in_progress')
    end
  end
end
