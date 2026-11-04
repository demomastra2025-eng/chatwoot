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
      'requested_context' => 'owned-context',
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
    unless client.is_a?(Telephony::Wazo::ApiClient)
      allow(client).to receive(:incalls).and_return([
                                                      { 'extensions' => [{ 'context' => 'owned-context', 'exten' => binding.phone_number }] }
                                                    ])
    end
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

  def offline_row
    row.merge('id' => 'missed-hop', 'date_answer' => nil,
              'destination_internal_exten' => nil, 'destination_exten' => binding.phone_number)
  end

  %w[inbound internal].each do |direction|
    context "with confirmed offline #{direction} evidence" do
      before do
        profile.destroy!
        connection.update!(metadata: { wazo_call_log_sync_enabled: true, wazo_incall_context: 'owned-context' })
        allow(client).to receive(:cdr).and_return('items' => [offline_row.merge('direction' => direction)])
      end

      it 'admits the owned row context without an operator' do
        expect { service.perform }.to change(Telephony::CallSession, :count).by(1)
        expect(account.telephony_call_sessions.sole).to have_attributes(direction: 'inbound', status: 'missed', answered_by: nil)
      end

      it 'uses metadata only when row context is absent' do
        allow(client).to receive(:cdr).and_return('items' => [offline_row.merge('direction' => direction, 'requested_context' => nil)])
        expect { service.perform }.to change(Telephony::CallSession, :count).by(1)
      end

      it 'rejects an explicit foreign context despite owned metadata' do
        allow(client).to receive(:cdr).and_return('items' => [offline_row.merge('direction' => direction, 'requested_context' => 'foreign-context')])
        expect { service.perform }.not_to change(Telephony::CallSession, :count)
      end

      it 'rejects missing incall evidence despite owned metadata' do
        allow(client).to receive(:incalls).and_return([])
        allow(client).to receive(:cdr).and_return('items' => [offline_row.merge('direction' => direction, 'requested_context' => nil)])
        expect { service.perform }.not_to change(Telephony::CallSession, :count)
      end

      it 'rejects incall context matching only a foreign DID' do
        allow(client).to receive(:incalls).and_return([{ 'extensions' => [{ 'context' => 'owned-context', 'exten' => '+77070009999' }] }])
        expect { service.perform }.not_to change(Telephony::CallSession, :count)
      end
    end
  end

  it 'missed hop followed by answered hop converges to completed' do
    allow(client).to receive(:cdr).and_return('items' => [offline_row, row])
    service.perform
    expect(account.telephony_call_sessions.last.status).to eq('completed')
    expect(account.telephony_call_sessions.count).to eq(1)
  end

  it 'answered hop followed by missed hop remains completed' do
    allow(client).to receive(:cdr).and_return('items' => [row, offline_row])
    service.perform
    expect(account.telephony_call_sessions.last.status).to eq('completed')
  end

  it 'later sync answered hop corrects earlier missed hop' do
    allow(client).to receive(:cdr).and_return('items' => [offline_row])
    service.perform
    allow(client).to receive(:cdr).and_return('items' => [row])
    described_class.new(connection: connection, client: client).perform
    expect(account.telephony_call_sessions.last.status).to eq('completed')
  end

  it 'missing configured operator still ingests DB internal offline schema with nil group' do
    connection.update!(metadata: { wazo_call_log_sync_enabled: true })
    allow(client).to receive(:incalls).and_return([{ 'extensions' => [{ 'context' => 'fake-incall', 'exten' => binding.phone_number }] }])
    allow(client).to receive(:cdr).and_return('items' => [offline_row.merge('direction' => 'internal', 'requested_context' => 'fake-incall',
                                                                            'requested_internal_exten' => nil)])
    service.perform
    expect(account.telephony_call_sessions.last.status).to eq('missed')
    expect(account.telephony_call_sessions.last.answered_by).to be_nil
  end

  it 'connection incall context covers CDR without requested_context' do
    connection.update!(metadata: { wazo_call_log_sync_enabled: true, wazo_incall_context: 'fake-incall' })
    allow(client).to receive(:incalls).and_return([{ 'extensions' => [{ 'context' => 'fake-incall', 'exten' => binding.phone_number }] }])
    allow(client).to receive(:cdr).and_return('items' => [offline_row.merge('direction' => 'internal', 'requested_context' => nil)])
    expect { service.perform }.to change(Telephony::CallSession, :count).by(1)
  end

  ['unknown', '', nil].each do |source|
    it "rejects unknown or empty caller #{source.inspect}" do
      allow(client).to receive(:cdr).and_return('items' => [offline_row.merge('source_exten' => source)])
      expect { service.perform }.not_to change(Telephony::CallSession, :count)
    end
  end

  context 'with real ApiClient incall transport' do
    let(:client) { Telephony::Wazo::ApiClient.new(base_url: 'https://wazo-review.example.com', username: 'fiction', password: 'fiction', tenant_uuid: 'tenant-example') }

    before do
      stub_request(:post, 'https://wazo-review.example.com/api/auth/0.1/token').to_return(status: 200, body: { data: { token: 'fiction' } }.to_json)
      allow(client).to receive(:cdr).and_return('items' => [offline_row.merge('direction' => 'internal', 'requested_context' => 'fake-incall')])
      allow(Rails.cache).to receive(:write).and_call_original
    end

    %w[inbound internal].each do |direction|
      it "uses owned DID and context from actual incalls JSON for #{direction}" do
        profile.destroy!
        connection.update!(metadata: { wazo_call_log_sync_enabled: true })
        allow(client).to receive(:cdr).and_return('items' => [offline_row.merge('direction' => direction, 'requested_context' => 'fake-incall')])
        stub_request(:get, 'https://wazo-review.example.com/api/confd/1.1/incalls?limit=1000')
          .with(headers: { 'Wazo-Tenant' => 'tenant-example', 'X-Auth-Token' => 'fiction' }).to_return(
            status: 200, body: { items: [{ extensions: [{ exten: binding.phone_number, context: 'fake-incall' }] }] }.to_json
          )
        expect { service.perform }.to change(Telephony::CallSession, :count).by(1)
      end
    end

    it 'permission error preserves cursor' do
      stub_request(:get, 'https://wazo-review.example.com/api/confd/1.1/incalls?limit=1000').to_return(status: 403, body: '{}')
      expect { service.perform }.to raise_error(Telephony::Error) { |e| expect(e.code).to eq('WAZO_TENANT_FORBIDDEN') }
      expect(Rails.cache).not_to have_received(:write).with(service.send(:cursor_key), anything, anything)
    end

    it 'malformed incall response must preserve cursor instead of skipping rows' do
      stub_request(:get, 'https://wazo-review.example.com/api/confd/1.1/incalls?limit=1000').to_return(status: 200, body: '{}')
      expect { service.perform }.to raise_error(Telephony::Error) { |error| expect(error.code).to eq('WAZO_API_RESPONSE_INVALID') }
      expect(account.telephony_call_sessions.count).to eq(0)
      expect(Rails.cache).not_to have_received(:write).with(service.send(:cursor_key), anything, anything)
    end
  end

  context 'when CDR hops describe one logical call' do
    [false, true].each do |separate_syncs|
      [false, true].each do |answer_first|
        it "preserves answered evidence with answer_first=#{answer_first}, separate_syncs=#{separate_syncs}" do
          missed = offline_row.merge('date_end' => (ended_at + 30.seconds).iso8601)
          hops = answer_first ? [row, missed] : [missed, row]
          if separate_syncs
            hops.each do |hop|
              allow(client).to receive(:cdr).and_return('items' => [hop])
              described_class.new(connection: connection, client: client).perform
            end
          else
            allow(client).to receive(:cdr).and_return('items' => hops)
            service.perform
          end
          expect_answered_call
          event_count = account.telephony_events.count
          allow(client).to receive(:cdr).and_return('items' => hops)
          2.times { described_class.new(connection: connection, client: client).perform }
          expect_answered_call
          expect(account.telephony_events.count).to eq(event_count)
        end
      end
    end

    it 'accepts a late answer revision of the same CDR row and replays both revisions' do
      missed = offline_row.merge('id' => row['id'])
      allow(client).to receive(:cdr).and_return('items' => [missed])
      service.perform
      expect(account.telephony_call_sessions.sole.answered_by).to be_nil
      allow(client).to receive(:cdr).and_return('items' => [row])
      described_class.new(connection: connection, client: client).perform
      expect_answered_call
      events = account.telephony_events.count
      allow(client).to receive(:cdr).and_return('items' => [missed, row])
      service.perform
      expect_answered_call
      expect(account.telephony_events.count).to eq(events)
    end

    it 'uses the exact CDR identity when browser correlation is ambiguous' do
      service.perform
      session = account.telephony_call_sessions.sole
      other = create(:telephony_call_session, account: account, inbox: inbox, number_binding: binding,
                                              conversation: session.conversation, contact: session.contact,
                                              provider: 'wazo', direction: 'inbound', started_at: started_at,
                                              from_number: session.from_number, to_number: session.to_number)
      expect(Telephony::Wazo::CallLogCorrelator.find(
               account: account, inbox: inbox, caller: session.from_number, did: session.to_number,
               direction: 'inbound', started_at: started_at, cdr_ref: 'wazo:cdr:conversation-one'
             )).to be_nil
      allow(client).to receive(:cdr).and_return('items' => [offline_row.merge('date_end' => (ended_at + 30.seconds).iso8601)])
      expect { service.perform }.not_to change(Telephony::CallSession, :count)
      expect(session.reload).to have_attributes(status: 'completed', duration_seconds: 45, answered_by: "user:#{user.id}")
      expect(other.reload.status).to eq('ringing')
    end

    it 'uses an exact linked browser CDR identity outside the correlation time window' do
      browser_event('browser-long-call', event: 'call_started')
      service.perform
      allow(client).to receive(:cdr).and_return('items' => [offline_row.merge('date' => (started_at + 120.seconds).iso8601,
                                                                              'date_end' => (ended_at + 180.seconds).iso8601)])
      service.perform
      expect_answered_call
    end

    it 'preserves a browser answer when an unanswered CDR hop arrives and replays' do
      browser_event('browser-answered', event: 'call_started')
      browser_event('browser-answered', event: 'completed', answered_at: answered_at.iso8601,
                                        answered_by: "user:#{user.id}", duration: 45, ended_at: ended_at.iso8601,
                                        occurred_at: ended_at.iso8601)
      allow(client).to receive(:cdr).and_return('items' => [offline_row.merge('date_end' => (ended_at + 30.seconds).iso8601)])
      2.times { described_class.new(connection: connection, client: client).perform }
      session = account.telephony_call_sessions.sole
      expect(session).to have_attributes(status: 'completed', duration_seconds: 45, answered_by: "user:#{user.id}")
      expect(session.conversation.messages.voice_calls.count).to eq(1)
      allow(client).to receive(:cdr).and_return('items' => [row])
      service.perform
      expect_answered_call
    end

    %w[before between after].each do |browser_timing|
      it "correlates a browser call #{browser_timing} missed and answered CDR hops" do
        browser_event('browser-hops', event: 'call_started') if browser_timing == 'before'
        allow(client).to receive(:cdr).and_return('items' => [offline_row])
        service.perform
        browser_event('browser-hops', event: 'call_started') if browser_timing == 'between'
        allow(client).to receive(:cdr).and_return('items' => [row])
        described_class.new(connection: connection, client: client).perform
        browser_event('browser-hops', event: 'call_started') if browser_timing == 'after'
        expect_answered_call
        allow(client).to receive(:cdr).and_return('items' => [offline_row, row])
        service.perform
        expect_answered_call
      end
    end
  end

  context 'when the incall context comes from connection metadata' do
    before do
      connection.update!(metadata: { wazo_call_log_sync_enabled: true, wazo_incall_context: 'owned-context' })
      allow(client).to receive(:incalls).and_return([
                                                      { 'extensions' => [{ 'context' => 'owned-context', 'exten' => binding.phone_number }] }
                                                    ])
      allow(client).to receive(:cdr).and_return('items' => [offline_row.merge('direction' => 'internal', 'requested_context' => context)])
    end

    let(:context) { 'foreign-context' }

    it 'does not hide an explicitly foreign row context with the metadata fallback' do
      expect { service.perform }.not_to change(Telephony::CallSession, :count)
    end

    context 'with an absent row context' do
      let(:context) { nil }

      it 'still requires the incall DID to be owned' do
        allow(client).to receive(:incalls).and_return([
                                                        { 'extensions' => [{ 'context' => 'owned-context', 'exten' => '+77070009999' }] }
                                                      ])
        expect { service.perform }.not_to change(Telephony::CallSession, :count)
      end
    end
  end

  def expect_answered_call
    session = account.telephony_call_sessions.sole
    expect(session).to have_attributes(status: 'completed', answered_at: answered_at,
                                       answered_by: "user:#{user.id}", duration_seconds: 45)
    expect(session.metadata.dig('metadata', 'wazo_cdr_ref')).to eq('wazo:cdr:conversation-one')
    message = session.conversation.messages.voice_calls.sole
    expect(message.content_attributes.dig('data', 'status')).to eq('completed')
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
