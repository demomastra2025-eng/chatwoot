require 'rails_helper'

RSpec.describe Telephony::CallReconciliationService do
  subject(:service) { described_class.new(account: account, now: now) }

  let(:account) { create(:account) }
  let(:now) { Time.zone.parse('2026-04-28T12:00:00Z') }

  describe '#perform' do
    it 'fails stale local Sipuni outbound calls that never receive a provider event' do
      conversation = create(
        :conversation,
        account: account,
        additional_attributes: {
          'call_status' => 'created',
          'call_direction' => 'outbound',
          'telephony_call_ref' => 'sipuni:local:stale-outbound-1'
        }
      )
      call_session = create(
        :telephony_call_session,
        account: account,
        conversation: conversation,
        contact: conversation.contact,
        inbox: conversation.inbox,
        provider: 'sipuni',
        external_call_ref: 'sipuni:local:stale-outbound-1',
        provider_call_sid: nil,
        status: 'created',
        direction: 'outbound',
        started_at: now - 2.minutes,
        last_event_at: now - 2.minutes,
        metadata: {
          'telephony_call_ref' => 'sipuni:local:stale-outbound-1',
          'metadata' => {
            'source' => 'onelink_browser_janus_sip',
            'provider' => 'sipuni',
            'route_action' => 'operator',
            'direction' => 'outbound',
            'call_direction' => 'outbound'
          }
        }
      )
      message = voice_call_message_for(call_session, conversation, message_type: :outgoing)

      with_modified_env('TELEPHONY_SIPUNI_LOCAL_OUTBOUND_MISSING_AFTER_SECONDS' => '30') do
        expect(service.perform).to include(checked: 1, missing: 1, updated: 1, errors: 0)
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
          'call_direction' => 'outbound'
        )
      end
    end

    it 'closes stale Sipuni provider inbound ringing calls and syncs the voice bubble' do
      conversation = create(
        :conversation,
        account: account,
        additional_attributes: {
          'call_status' => 'ringing',
          'call_direction' => 'inbound',
          'telephony_call_ref' => 'sipuni:1782827000.500001'
        }
      )
      call_session = create(
        :telephony_call_session,
        account: account,
        conversation: conversation,
        contact: conversation.contact,
        inbox: conversation.inbox,
        provider: 'sipuni',
        external_call_ref: 'sipuni:1782827000.500001',
        provider_call_sid: '1782827000.500001',
        status: 'ringing',
        direction: 'inbound',
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
      message = voice_call_message_for(call_session, conversation, message_type: :incoming)

      with_modified_env('TELEPHONY_SIPUNI_PROVIDER_RINGING_STALE_AFTER_SECONDS' => '120') do
        expect(service.perform).to include(checked: 1, missing: 1, updated: 1, errors: 0)
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
        expect(service.perform).to include(checked: 0, missing: 0, updated: 0, errors: 0)
      end

      expect(call_session.reload.status).to eq('in_progress')
    end

    it 'closes stale native Asterisk Janus ringing calls and syncs the voice bubble' do
      call_ref = 'asterisk_analog:janus:41:deadbeef@10.77.0.2'
      conversation = create(
        :conversation,
        account: account,
        additional_attributes: {
          'call_status' => 'ringing',
          'call_direction' => 'inbound',
          'telephony_call_ref' => call_ref
        }
      )
      call_session = create(
        :telephony_call_session,
        account: account,
        conversation: conversation,
        contact: conversation.contact,
        inbox: conversation.inbox,
        provider: 'asterisk_analog',
        external_call_ref: call_ref,
        provider_call_sid: nil,
        status: 'ringing',
        direction: 'inbound',
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
      message = voice_call_message_for(call_session, conversation, message_type: :incoming)

      with_modified_env('TELEPHONY_NATIVE_SIP_PRE_ANSWER_STALE_AFTER_SECONDS' => '120') do
        expect(service.perform).to include(checked: 1, missing: 1, updated: 1, errors: 0)
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
        expect(service.perform).to include(checked: 1, missing: 1, updated: 1, errors: 0)
      end

      expect(call_session.reload).to have_attributes(
        status: 'completed',
        ended_at: now,
        ended_by: 'native_sip_reconciliation',
        end_reason: 'native_sip_missing_completed_call',
        duration_seconds: 15_300
      )
    end

    it 'closes stale native Asterisk local outbound calls without a terminal browser event' do
      call_ref = 'asterisk_analog:local:stale-outbound-1'
      conversation = create(
        :conversation,
        account: account,
        additional_attributes: {
          'call_status' => 'created',
          'call_direction' => 'outbound',
          'telephony_call_ref' => call_ref
        }
      )
      call_session = create(
        :telephony_call_session,
        account: account,
        conversation: conversation,
        contact: conversation.contact,
        inbox: conversation.inbox,
        provider: 'asterisk_analog',
        external_call_ref: call_ref,
        provider_call_sid: nil,
        status: 'created',
        direction: 'outbound',
        started_at: now - 2.minutes,
        last_event_at: now - 2.minutes,
        metadata: {
          'metadata' => {
            'source' => 'onelink_browser_janus_sip',
            'provider' => 'asterisk_analog',
            'route_action' => 'operator',
            'direction' => 'outbound',
            'call_direction' => 'outbound'
          }
        }
      )
      message = voice_call_message_for(call_session, conversation, message_type: :outgoing)

      with_modified_env('TELEPHONY_NATIVE_SIP_LOCAL_OUTBOUND_MISSING_AFTER_SECONDS' => '30') do
        expect(service.perform).to include(checked: 1, missing: 1, updated: 1, errors: 0)
      end

      aggregate_failures do
        expect(call_session.reload).to have_attributes(
          status: 'no_answer',
          ended_at: now,
          ended_by: 'native_sip_reconciliation',
          end_reason: 'native_sip_missing_outbound_no_answer',
          duration_seconds: 0
        )
        expect(message.reload.content_attributes.dig('data', 'status')).to eq('no_answer')
      end
    end

    it 'ignores old non-Janus call refs without provider-owned Sipuni ids' do
      call_session = create(
        :telephony_call_session,
        account: account,
        provider: 'sipuni',
        external_call_ref: 'legacy-call-ref',
        provider_call_sid: nil,
        status: 'ringing',
        direction: 'inbound',
        started_at: now - 10.minutes,
        last_event_at: now - 10.minutes
      )

      expect(service.perform).to include(checked: 0, missing: 0, updated: 0, errors: 0)
      expect(call_session.reload.status).to eq('ringing')
    end
  end

  def voice_call_message_for(call_session, conversation, message_type:)
    conversation.messages.create!(
      account: account,
      inbox: call_session.inbox,
      message_type: message_type,
      content_type: :voice_call,
      content: 'Voice Call',
      source_id: call_session.voice_call_source_id,
      content_attributes: {
        'data' => {
          'call_sid' => call_session.external_call_ref,
          'status' => call_session.status,
          'call_direction' => call_session.direction
        }
      }
    )
  end
end
