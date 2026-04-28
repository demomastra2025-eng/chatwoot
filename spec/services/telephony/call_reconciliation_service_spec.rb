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
      expect(call_session.legs.last).to include(
        'source' => 'bridge_reconciliation',
        'status' => 'busy',
        'provider_status' => 'BUSY'
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
  end
end
