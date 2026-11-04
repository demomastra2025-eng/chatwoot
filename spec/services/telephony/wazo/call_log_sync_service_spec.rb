# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telephony::Wazo::CallLogSyncService do
  let(:account) { create(:account) }
  let(:connection) do
    create(:telephony_provider_connection, account: account, provider_kind: 'wazo', status: 'active',
                                           metadata: { wazo_call_log_sync_enabled: true,
                                                       wazo_call_log_sync_operator_extension: '101' })
  end
  let(:channel) do
    create(:channel_voice, account: account, provider: 'wazo', phone_number: '+77070001001',
                           provider_config: { number_ref: 'wazo-did-one', provider_connection_id: connection.id,
                                              routing_mode: 'operator' })
  end
  let(:inbox) { channel.inbox }
  let(:binding) { Telephony::NumberBinding.sync_from_voice_channel!(channel) }
  let(:user) { create(:user, account: account, role: :agent) }
  let!(:profile) do
    binding
    create(:telephony_sip_profile, account: account, inbox: inbox, provider_connection: connection,
                                   user: user, internal_extension: '101', status: 'active')
  end
  let(:client) { instance_double(Telephony::Wazo::ApiClient) }
  let(:started_at) { 2.minutes.ago.change(usec: 0) }
  let(:answered_at) { started_at + 15.seconds }
  let(:ended_at) { answered_at + 45.seconds }
  let(:row) do
    {
      'id' => 'cdr-one', 'conversation_id' => 'conversation-one',
      'date' => started_at.iso8601, 'date_answer' => answered_at.iso8601,
      'date_end' => ended_at.iso8601, 'direction' => 'inbound',
      'source_exten' => '+77071112233', 'requested_exten' => binding.phone_number,
      'destination_exten' => '101', 'destination_internal_exten' => '101',
      'reached_voicemail' => false
    }
  end
  let(:service) { described_class.new(connection: connection, client: client) }

  around do |example|
    with_modified_env(TELEPHONY_WAZO_CALL_LOG_SYNC_ENABLED: 'true', TELEPHONY_WAZO_TENANT_UUID: 'tenant-example') do
      example.run
    end
  end

  before do
    binding
    allow(client).to receive(:cdr).and_return('items' => [row])
  end

  it 'records an answered inbound call with operator and duration' do
    service.perform

    session = account.telephony_call_sessions.find_by!(external_call_ref: 'wazo:cdr:conversation-one')
    expect(session).to have_attributes(status: 'completed', direction: 'inbound', duration_seconds: 45,
                                       answered_by: "user:#{user.id}", inbox_id: inbox.id)
    expect(session.conversation.messages.voice_calls.count).to eq(1)
  end

  it 'records a missed call and its timeline message' do
    row['date_answer'] = nil
    service.perform

    session = account.telephony_call_sessions.find_by!(external_call_ref: 'wazo:cdr:conversation-one')
    expect(session).to have_attributes(status: 'missed', answered_at: nil)
    expect(session.conversation.messages.voice_calls.first.content_attributes.dig('data', 'status')).to eq('missed')
  end

  it 'marks voicemail on the timeline without importing a recording' do
    row['reached_voicemail'] = true
    service.perform

    session = account.telephony_call_sessions.find_by!(external_call_ref: 'wazo:cdr:conversation-one')
    expect(session.end_reason).to eq('voicemail')
    expect(session).to have_attributes(status: 'missed', answered_by: nil)
    expect(session.recording_ref).to be_nil
    expect(session.conversation.messages.voice_calls.first.content_attributes.dig('data', 'meta', 'reached_voicemail')).to be(true)
  end

  it 'records an outbound call against the line DID' do
    row.merge!('direction' => 'outbound', 'source_exten' => '101',
               'source_internal_exten' => '101', 'source_line_identity' => binding.phone_number,
               'destination_exten' => '+77071112233')
    service.perform

    session = account.telephony_call_sessions.find_by!(external_call_ref: 'wazo:cdr:conversation-one')
    expect(session).to have_attributes(direction: 'outbound', status: 'completed',
                                       from_number: binding.phone_number, to_number: '+77071112233')
    expect(session.conversation.messages.voice_calls.count).to eq(1)
  end

  it 'skips a DID that is not bound to this connection' do
    row['requested_exten'] = '+77070009999'
    expect { service.perform }.not_to change(Telephony::CallSession, :count)
  end

  it 'skips another operator extension' do
    row['destination_internal_exten'] = '102'
    expect { service.perform }.not_to change(Telephony::CallSession, :count)
  end

  it 'honors a connection opt-out' do
    connection.update!(metadata: { wazo_call_log_sync_enabled: false })
    service.perform
    expect(client).not_to have_received(:cdr)
  end

  it 'does not duplicate a session or message on a repeated CDR' do
    service.perform
    expect { service.perform }.not_to change(Telephony::CallSession, :count)
    expect(account.telephony_call_sessions.last.conversation.messages.voice_calls.count).to eq(1)
  end

  it 'enriches a browser call when its CDR arrives later' do
    browser_event('browser-one', event: 'call_started')
    browser_event('browser-one', event: 'completed', occurred_at: ended_at.iso8601, ended_at: ended_at.iso8601)
    before_count = account.telephony_call_sessions.count

    service.perform

    session = account.telephony_call_sessions.find_by!(external_call_ref: 'browser-one')
    expect(account.telephony_call_sessions.count).to eq(before_count)
    expect(session.metadata.dig('metadata', 'wazo_cdr_ref')).to eq('wazo:cdr:conversation-one')
    expect(session.conversation.messages.voice_calls.count).to eq(1)
  end

  it 'reuses the CDR session when a browser event arrives later' do
    service.perform
    before_count = account.telephony_call_sessions.count

    browser_event('browser-later', event: 'call_started')

    expect(account.telephony_call_sessions.count).to eq(before_count)
    session = account.telephony_call_sessions.find_by!(external_call_ref: 'wazo:cdr:conversation-one')
    expect(session.conversation.messages.voice_calls.count).to eq(1)
  end

  it 'makes no HTTP call when the feature flag is off' do
    with_modified_env(TELEPHONY_WAZO_CALL_LOG_SYNC_ENABLED: nil) { service.perform }
    expect(client).not_to have_received(:cdr)
  end

  it 'leaves the cursor unchanged when the API fails' do
    allow(client).to receive(:cdr).and_raise(Telephony::Error.new(code: 'WAZO_API_UNAVAILABLE', message: 'Unavailable'))
    expect { service.perform }.to raise_error(Telephony::Error)
  end

  it 'downloads CDR recording media when present and session has no recording_ref' do
    wav_bytes = "RIFF\x24\x00\x00\x00WAVEfmt "
    row['recordings'] = [{ 'uuid' => 'rec-uuid-123' }]
    expect(client).to receive(:cdr_recording_media).with('cdr-one', 'rec-uuid-123').and_return(wav_bytes)
    allow(Telephony::CompressRecordingsJob).to receive(:perform_later)

    service.perform

    session = account.telephony_call_sessions.find_by!(external_call_ref: 'wazo:cdr:conversation-one')
    expect(session.recording_ref).to start_with("voice-recordings/wazo/#{account.id}/")
    expect(session.recording_ref).to end_with(".wav")
    expect(Telephony::CompressRecordingsJob).to have_received(:perform_later).with(call_session_id: session.id)
  end

  context 'with an offline ring group incall' do
    before do
      row.delete('direction')
      row.delete('source_exten')
      row.delete('requested_exten')
      row.delete('destination_exten')
      row.delete('destination_internal_exten')
      row.merge!('call_direction' => 'internal', 'source_extension' => '+77071112233',
                 'requested_extension' => binding.phone_number, 'destination_extension' => binding.phone_number,
                 'requested_context' => 'fake-incall-context', 'requested_internal_extension' => '2099',
                 'destination_internal_extension' => nil, 'answered' => false, 'date_answer' => nil)
      allow(client).to receive(:incalls).and_return([
                                                      { 'extensions' => [{ 'context' => 'fake-incall-context', 'exten' => binding.phone_number }],
                                                        'destination' => { 'type' => 'group', 'group_id' => 42 } }
                                                    ])
      profile.destroy!
      connection.update!(metadata: { wazo_call_log_sync_enabled: true })
    end

    it 'records an owned missed inbound call without an operator and deduplicates the CDR' do
      expect { service.perform }.to change(Telephony::CallSession, :count).by(1)
      session = account.telephony_call_sessions.last
      expect(session).to have_attributes(direction: 'inbound', status: 'missed', answered_at: nil, answered_by: nil,
                                         account_id: account.id, inbox_id: inbox.id, number_binding_id: binding.id,
                                         from_number: '+77071112233', to_number: binding.phone_number)
      expect(session.metadata.dig('metadata', 'chatwoot_user_id')).to be_nil
      expect { service.perform }.not_to change(Telephony::CallSession, :count)
      expect(session.conversation.messages.voice_calls.count).to eq(1)
      expect(session.conversation.messages.voice_calls.first.content_attributes.dig('data', 'status')).to eq('missed')
    end

    it 'accepts the explicit inbound schema without a configured operator extension' do
      row['call_direction'] = 'inbound'
      expect { service.perform }.to change(Telephony::CallSession, :count).by(1)
      expect(account.telephony_call_sessions.last.answered_by).to be_nil
    end

    it 'rejects an unknown DID even if the incall context exists' do
      row.merge!('requested_extension' => '+77070009999', 'destination_extension' => '+77070009999')
      expect { service.perform }.not_to change(Telephony::CallSession, :count)
    end

    it 'rejects a DID belonging only to another account' do
      other_account = create(:account)
      other_connection = create(:telephony_provider_connection, account: other_account, provider_kind: 'wazo')
      other_channel = create(:channel_voice, account: other_account, provider: 'wazo', phone_number: '+77070001002',
                                             provider_config: { number_ref: 'other-did', provider_connection_id: other_connection.id })
      other_binding = Telephony::NumberBinding.sync_from_voice_channel!(other_channel)
      row.merge!('requested_extension' => other_binding.phone_number, 'destination_extension' => other_binding.phone_number)
      expect { service.perform }.not_to change(Telephony::CallSession, :count)
    end

    it 'rejects another connection on the same account' do
      channel.update!(provider_config: channel.provider_config_hash.merge('provider_connection_id' => connection.id + 1000))
      expect { service.perform }.not_to change(Telephony::CallSession, :count)
    end

    it 'rejects an ambiguous DID instead of selecting the first inbox' do
      create(:telephony_number_binding, account: account, provider_connection: connection,
                                        provider: 'wazo', phone_number: binding.phone_number, ingress_number: binding.phone_number)
      expect { service.perform }.not_to change(Telephony::CallSession, :count)
    end

    it 'rejects an internal call with a short caller even if the DID is present' do
      row['source_extension'] = '102'
      expect { service.perform }.not_to change(Telephony::CallSession, :count)
    end

    it 'rejects ordinary answered short to short calls' do
      row.merge!('source_extension' => '102', 'requested_extension' => '2099', 'destination_extension' => '101',
                 'answered' => true, 'date_answer' => answered_at.iso8601, 'destination_internal_extension' => '101')
      expect { service.perform }.not_to change(Telephony::CallSession, :count)
    end

    it 'does not infer inbound from an answered internal call to a known DID' do
      row.merge!('answered' => true, 'date_answer' => answered_at.iso8601)
      expect { service.perform }.not_to change(Telephony::CallSession, :count)
    end

    it 'does not turn an explicit inbound answer with no operator into a missed call' do
      row.merge!('call_direction' => 'inbound', 'answered' => true, 'date_answer' => answered_at.iso8601)
      expect { service.perform }.not_to change(Telephony::CallSession, :count)
    end

    it 'requires a matching incall DID and context to reclassify internal CDRs' do
      row['requested_context'] = 'another-tenant-context'
      expect { service.perform }.not_to change(Telephony::CallSession, :count)
    end

    it 'rejects an internal source identity even if its public caller ID is a phone number' do
      row['source_internal_extension'] = '102'
      expect { service.perform }.not_to change(Telephony::CallSession, :count)
    end
  end

  private

  def browser_event(ref, event:, **attributes)
    Telephony::EventsIngestionService.new(payload: {
      account_id: account.id, inbox_id: inbox.id, number_ref: binding.number_ref,
      call_ref: ref, event_key: "#{ref}:#{event}", provider: 'wazo', event: event,
      direction: 'inbound', from_number: '+77071112233', to_number: binding.phone_number,
      started_at: started_at.iso8601, occurred_at: started_at.iso8601
    }.merge(attributes)).perform
  end
end
