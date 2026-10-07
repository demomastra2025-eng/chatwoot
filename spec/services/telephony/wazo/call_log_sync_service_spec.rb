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
  let(:binding) { Telephony::NumberBinding.find_by!(inbox: inbox) }
  let(:user) { create(:user, account: account, role: :agent) }
  let!(:profile) do
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
