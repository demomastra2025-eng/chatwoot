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

    it 'closes native Binotel Janus in-progress calls after the one-hour default' do
      call_session = create(
        :telephony_call_session,
        account: account,
        provider: 'binotel',
        external_call_ref: 'binotel:janus:42:stale-active@pbx.example.test',
        provider_call_sid: nil,
        status: 'in_progress',
        direction: 'outbound',
        started_at: now - 2.hours,
        answered_at: now - 90.minutes,
        last_event_at: now - 90.minutes,
        metadata: {
          'metadata' => {
            'source' => 'onelink_browser_janus_sip',
            'provider' => 'binotel'
          }
        }
      )

      expect(service.perform).to include(checked: 1, missing: 1, updated: 1, errors: 0)

      expect(call_session.reload).to have_attributes(
        status: 'completed',
        ended_at: now,
        ended_by: 'native_sip_reconciliation',
        end_reason: 'native_sip_missing_completed_call',
        duration_seconds: 5400
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

    it 'closes stale generic pre-answer legacy Sipuni calls and syncs the voice bubble idempotently' do
      conversation = create(
        :conversation,
        account: account,
        additional_attributes: {
          'call_status' => 'ringing',
          'call_direction' => 'inbound',
          'telephony_call_ref' => 'sipuni:legacy:stale-inbound-1'
        }
      )
      call_session = create(
        :telephony_call_session,
        account: account,
        conversation: conversation,
        contact: conversation.contact,
        inbox: conversation.inbox,
        provider: 'sipuni',
        external_call_ref: 'sipuni:legacy:stale-inbound-1',
        provider_call_sid: nil,
        status: 'ringing',
        direction: 'inbound',
        started_at: now - 2.hours,
        last_event_at: now - 2.hours,
        metadata: {
          'metadata' => {
            'source' => 'legacy_sipuni_webhook',
            'provider' => 'sipuni',
            'route_action' => 'operator',
            'route_reason' => 'operator_ring_timeout'
          }
        }
      )
      message = voice_call_message_for(call_session, conversation, message_type: :incoming)

      expect(service.perform).to include(checked: 1, missing: 1, updated: 1, errors: 0)

      event_key = "generic_pre_answer_reconciliation:#{account.id}:#{call_session.external_call_ref}:no_answer:#{now.to_i}"
      event = account.telephony_events.find_by!(event_key: event_key)
      aggregate_failures do
        expect(call_session.reload).to have_attributes(
          status: 'no_answer',
          ended_at: now,
          ended_by: 'generic_pre_answer_reconciliation',
          end_reason: 'generic_pre_answer_stale_operator_no_answer',
          duration_seconds: 0
        )
        expect(call_session.metadata['generic_pre_answer_reconciliation']).to include(
          'source' => 'generic_pre_answer_reconciliation',
          'pre_answer_stale' => true,
          'target_status' => 'no_answer',
          'previous_status' => 'ringing',
          'stale_after_seconds' => 3600,
          'provider' => 'sipuni',
          'route_action' => 'operator'
        )
        expect(call_session.legs).to include(a_hash_including(
                                               'source' => 'generic_pre_answer_reconciliation',
                                               'status' => 'no_answer',
                                               'end_reason' => 'generic_pre_answer_stale_operator_no_answer',
                                               'pre_answer_stale' => true
                                             ))
        expect(event.payload).to include(
          'status' => 'no_answer',
          'end_reason' => 'generic_pre_answer_stale_operator_no_answer',
          'ended_by' => 'generic_pre_answer_reconciliation'
        )
        expect(event.payload.dig('metadata', 'source')).to eq('generic_pre_answer_reconciliation')
        expect(message.reload.content_attributes.dig('data', 'status')).to eq('no_answer')
        expect(conversation.reload.additional_attributes).to include('call_status' => 'no_answer')
      end

      expect { service.perform }.not_to(change { account.telephony_events.where(event_key: event_key).count })
      expect(Telephony::EventsIngestionService::RECONCILIATION_EVENT_SOURCES).to include('generic_pre_answer_reconciliation')
    end

    it 'uses outbound, operator inbound, and other inbound generic pre-answer semantics' do
      sessions = [
        create_generic_pre_answer_session(direction: 'outbound', status: 'created', route_action: 'operator'),
        create_generic_pre_answer_session(direction: 'inbound', status: 'ringing', route_action: 'operator'),
        create_generic_pre_answer_session(direction: 'inbound', status: 'connecting', route_action: 'ai')
      ]

      expect(service.perform).to include(checked: 3, missing: 3, updated: 3, errors: 0)

      expect(sessions.map { |session| session.reload.status }).to eq(%w[no_answer no_answer missed])
      expect(sessions.map(&:end_reason)).to eq(%w[
                                                 generic_pre_answer_stale_outbound_no_answer
                                                 generic_pre_answer_stale_operator_no_answer
                                                 generic_pre_answer_stale_inbound_missed
                                               ])
    end

    it 'does not close fresh generic pre-answer or in-progress calls' do
      fresh_session = create_generic_pre_answer_session(
        direction: 'inbound',
        status: 'ringing',
        route_action: 'operator',
        started_at: now - 2.hours,
        last_event_at: now - 30.minutes
      )
      in_progress_session = create_generic_pre_answer_session(
        direction: 'inbound',
        status: 'in_progress',
        route_action: 'operator',
        started_at: now - 2.hours,
        last_event_at: now - 2.hours
      )

      expect(service.perform).to include(checked: 0, missing: 0, updated: 0, errors: 0)
      expect(fresh_session.reload.status).to eq('ringing')
      expect(in_progress_session.reload.status).to eq('in_progress')
    end

    it 'uses the latest last_event_at instead of an old started_at for generic staleness' do
      call_session = create_generic_pre_answer_session(
        direction: 'inbound',
        status: 'ringing',
        route_action: 'operator',
        started_at: now - 2.hours,
        last_event_at: now - 30.minutes
      )

      expect(service.perform).to include(checked: 0, missing: 0, updated: 0, errors: 0)
      expect(call_session.reload.status).to eq('ringing')
    end

    it 'falls back to the one-hour default for a non-positive generic stale threshold' do
      call_session = create_generic_pre_answer_session(
        direction: 'inbound',
        status: 'ringing',
        route_action: 'ai',
        started_at: now - 30.minutes,
        last_event_at: now - 30.minutes
      )

      with_modified_env('TELEPHONY_GENERIC_PRE_ANSWER_STALE_AFTER_SECONDS' => '0') do
        expect(service.send(:generic_pre_answer_stale_after)).to eq(1.hour)
        expect(service.perform).to include(checked: 0, missing: 0, updated: 0, errors: 0)
      end
      expect(call_session.reload.status).to eq('ringing')
    end

    it 'limits generic reconciliation to the requested account' do
      in_scope = create_generic_pre_answer_session(account: account, direction: 'inbound', route_action: 'ai')
      out_of_scope = create_generic_pre_answer_session(account: create(:account), direction: 'inbound', route_action: 'ai')

      expect(service.perform).to include(checked: 1, missing: 1, updated: 1, errors: 0)
      expect(in_scope.reload.status).to eq('missed')
      expect(out_of_scope.reload.status).to eq('ringing')
    end

    it 'rechecks a generic candidate under lock before closing it' do
      call_session = create_generic_pre_answer_session(direction: 'inbound', route_action: 'ai')
      allow(service).to receive(:reconcile_stale_session).and_wrap_original do |original, candidate, **options, &block|
        candidate.update_columns(last_event_at: now - 5.minutes)
        original.call(candidate, **options, &block)
      end

      expect(service.perform).to include(checked: 1, missing: 1, updated: 0, errors: 0)
      expect(call_session.reload).to have_attributes(status: 'ringing', ended_at: nil)
    end

    it 'keeps provider-specific sessions on their configured timeout instead of the generic timeout' do
      call_session = create(
        :telephony_call_session,
        account: account,
        provider: 'sipuni',
        external_call_ref: 'sipuni:local:provider-specific-timeout',
        provider_call_sid: nil,
        status: 'created',
        direction: 'outbound',
        started_at: now - 90.minutes,
        last_event_at: now - 90.minutes
      )

      with_modified_env(
        'TELEPHONY_GENERIC_PRE_ANSWER_STALE_AFTER_SECONDS' => '3600',
        'TELEPHONY_SIPUNI_LOCAL_OUTBOUND_MISSING_AFTER_SECONDS' => '7200'
      ) do
        configured_service = described_class.new(account: account, now: now)
        expect(configured_service.perform).to include(checked: 0, missing: 0, updated: 0, errors: 0)
      end

      expect(call_session.reload.status).to eq('created')
    end

    it 'does not close a stale pre-answer status when answer evidence exists' do
      call_session = create_generic_pre_answer_session(direction: 'inbound', route_action: 'operator')
      call_session.update!(
        legs: [{
          'event_type' => 'operator_answered',
          'status' => 'in_progress',
          'occurred_at' => (now - 90.minutes).iso8601
        }]
      )

      expect(service.perform).to include(checked: 1, missing: 1, updated: 0, errors: 0)
      expect(call_session.reload).to have_attributes(status: 'ringing', ended_at: nil)
    end

    it 'falls back to safe defaults for invalid provider-specific timeout values' do
      invalid_env = {
        'TELEPHONY_SIPUNI_LOCAL_OUTBOUND_MISSING_AFTER_SECONDS' => '0',
        'TELEPHONY_SIPUNI_PROVIDER_RINGING_STALE_AFTER_SECONDS' => '-1',
        'TELEPHONY_SIPUNI_PROVIDER_IN_PROGRESS_STALE_AFTER_SECONDS' => 'invalid',
        'TELEPHONY_NATIVE_SIP_PRE_ANSWER_STALE_AFTER_SECONDS' => '0',
        'TELEPHONY_NATIVE_SIP_IN_PROGRESS_STALE_AFTER_SECONDS' => '-1',
        'TELEPHONY_NATIVE_SIP_LOCAL_OUTBOUND_MISSING_AFTER_SECONDS' => 'invalid'
      }

      with_modified_env(invalid_env) do
        configured_service = described_class.new(account: account, now: now)
        expect(configured_service.send(:sipuni_local_outbound_missing_after)).to eq(60.seconds)
        expect(configured_service.send(:sipuni_provider_ringing_stale_after)).to eq(5.minutes)
        expect(configured_service.send(:sipuni_provider_in_progress_stale_after)).to eq(1.hour)
        expect(configured_service.send(:native_sip_pre_answer_stale_after)).to eq(5.minutes)
        expect(configured_service.send(:native_sip_in_progress_stale_after)).to eq(1.hour)
        expect(configured_service.send(:native_sip_local_outbound_missing_after)).to eq(60.seconds)
      end
    end

    it 'retries failed generic reconciliation side effects on the next scheduled run' do
      conversation = create(:conversation, account: account, additional_attributes: { 'call_status' => 'ringing' })
      call_session = create_generic_pre_answer_session(
        account: account,
        conversation: conversation,
        direction: 'inbound',
        route_action: 'operator'
      )
      message = voice_call_message_for(call_session, conversation, message_type: :incoming)

      expect(service.perform).to include(updated: 1, errors: 0)
      event = account.telephony_events.find_by!(call_session: call_session, event_type: 'no_answer')
      event.update!(status: 'failed', error_message: 'temporary side-effect failure')
      message.update!(content_attributes: message.content_attributes.deep_merge('data' => { 'status' => 'ringing' }))
      conversation.update!(additional_attributes: conversation.additional_attributes.merge('call_status' => 'ringing'))

      expect(service.perform).to include(checked: 0, updated: 0, errors: 0)
      expect(event.reload).to have_attributes(status: 'processed', error_message: nil)
      expect(message.reload.content_attributes.dig('data', 'status')).to eq('no_answer')
      expect(conversation.reload.additional_attributes['call_status']).to eq('no_answer')
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

  def create_generic_pre_answer_session(
    direction:,
    route_action:,
    account: self.account,
    conversation: nil,
    status: 'ringing',
    started_at: now - 2.hours,
    last_event_at: now - 2.hours
  )
    conversation ||= create(:conversation, account: account)
    create(
      :telephony_call_session,
      account: account,
      conversation: conversation,
      contact: conversation.contact,
      inbox: conversation.inbox,
      provider: 'legacy_provider',
      external_call_ref: "legacy:generic:#{SecureRandom.hex(8)}",
      provider_call_sid: nil,
      status: status,
      direction: direction,
      started_at: started_at,
      last_event_at: last_event_at,
      metadata: {
        'metadata' => {
          'source' => 'legacy_telephony',
          'provider' => 'legacy_provider',
          'route_action' => route_action
        }
      }
    )
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
