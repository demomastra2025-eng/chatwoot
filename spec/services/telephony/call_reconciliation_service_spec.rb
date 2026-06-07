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

    it 'syncs the voice-call bubble when reconciliation finalizes a call' do
      voice_channel = create(:channel_voice, :fonoster, account: account, phone_number: '+77172705175')
      voice_inbox = voice_channel.inbox
      contact = create(:contact, account: account, phone_number: '+77066318623')
      contact_inbox = create(:contact_inbox, contact: contact, inbox: voice_inbox, source_id: contact.phone_number)
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
        }
      )
      bridge_items << {
        'ref' => 'call-ref-sync-message',
        'status' => 'UNKNOWN',
        'startedAt' => (now - 2.minutes).iso8601,
        'endedAt' => (now - 30.seconds).iso8601,
        'duration' => 0,
        'direction' => 'TO_PSTN'
      }

      service.perform

      expect(call_session.reload.status).to eq('no_answer')
      expect(message.reload.content_attributes.dig('data', 'status')).to eq('no_answer')
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
