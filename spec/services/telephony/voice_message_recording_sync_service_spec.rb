require 'rails_helper'

RSpec.describe Telephony::VoiceMessageRecordingSyncService do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:storage_key) { 'voice-recordings/janus/1/call/final.wav' }
  let(:call_session) do
    create(
      :telephony_call_session,
      account: account,
      inbox: inbox,
      conversation: conversation,
      external_call_ref: 'sipuni:local:recording-sync',
      direction: 'outbound',
      status: 'completed',
      recording_ref: storage_key,
      metadata: {
        'recording' => {
          'recording_ref' => storage_key,
          'storage_key' => storage_key,
          'recorded_by' => 'janus',
          'layout' => 'dual_channel',
          'content_type' => 'audio/wav'
        }
      }
    )
  end

  def create_voice_message(data, session = call_session)
    create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      content_type: :voice_call,
      source_id: session.voice_call_source_id,
      content_attributes: { 'data' => data }
    )
  end

  it 'replaces stale browser metadata and token with the authoritative Janus recording' do
    browser_key = 'voice-recordings/sipuni/1/call/browser.webm'
    browser_url = Telephony::CallRecordingPlaybackUrl.path_for(call_session, storage_key: browser_key)
    message = create_voice_message(
      'recording_ref' => browser_key,
      'recording_url' => browser_url,
      'recording' => { 'storage_key' => browser_key, 'content_type' => 'audio/webm' }
    )

    described_class.new(call_session: call_session).perform

    data = message.reload.content_attributes.fetch('data')
    token = Rack::Utils.parse_nested_query(URI.parse(data.fetch('recording_url')).query).fetch('recording_token')
    expect(data['recording_ref']).to eq(storage_key)
    expect(data['recording']).to include(
      'storage_key' => storage_key,
      'recorded_by' => 'janus',
      'layout' => 'dual_channel',
      'content_type' => 'audio/wav'
    )
    expect(Telephony::CallRecordingPlaybackUrl.valid?(token: token, call_session: call_session,
                                                      storage_key: storage_key)).to be(true)
  end

  it 'does not expose a stored recording when the message presentation intentionally omitted it' do
    message = create_voice_message('call_sid' => call_session.external_call_ref, 'status' => 'completed')
    original_attributes = message.content_attributes.deep_dup

    described_class.new(call_session: call_session).perform

    expect(message.reload.content_attributes).to eq(original_attributes)
  end

  it 'updates the canonical message when the recording belongs to a duplicate runtime branch' do
    logical_key = 'janus-inbound:recording-sync-group'
    root_session = create(
      :telephony_call_session,
      account: account,
      inbox: inbox,
      conversation: conversation,
      number_binding: call_session.number_binding,
      provider: call_session.provider,
      direction: call_session.direction,
      external_call_ref: 'sipuni:local:recording-sync-root',
      metadata: { 'metadata' => { 'logical_call_key' => logical_key,
                                  'logical_call_group_ref' => 'sipuni:local:recording-sync-root' } }
    )
    call_session.update!(metadata: call_session.metadata.deep_merge(
      'metadata' => { 'logical_call_key' => logical_key, 'logical_call_group_ref' => root_session.external_call_ref }
    ))
    browser_key = 'voice-recordings/sipuni/1/call/browser.webm'
    message = create_voice_message(
      {
        'recording_ref' => browser_key,
        'recording' => { 'storage_key' => browser_key, 'content_type' => 'audio/webm' }
      },
      root_session
    )

    synced_message = described_class.new(call_session: call_session).perform

    expect(synced_message).to eq(message)
    expect(message.reload.content_attributes.dig('data', 'recording', 'storage_key')).to eq(storage_key)
  end
end
