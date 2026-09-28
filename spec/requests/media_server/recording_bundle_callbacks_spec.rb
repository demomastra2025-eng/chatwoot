require 'rails_helper'

RSpec.describe 'Recording bundle ready callbacks', type: :request do
  let(:call) { create(:call, status: 'completed', media_session_id: 'session_test') }
  let(:digest) { 'a' * 64 }
  let(:payload) do
    { session_id: call.media_session_id, account_id: call.account_id, call_id: call.provider_call_id,
      recording_manifest_version: 1, recording_manifest_sha256: digest }
  end

  before { allow(Whatsapp::CallRecordingFetchJob).to receive(:perform_later) }

  def ready_callback(params = payload, authenticated: true)
    headers = authenticated ? { 'Authorization' => 'Bearer synthetic-token' } : {}
    with_modified_env(MEDIA_SERVER_AUTH_TOKEN: 'synthetic-token') do
      post '/callbacks/media_server/recording_ready', params: params, headers: headers, as: :json
    end
  end

  it 'enqueues an explicitly versioned bundle even when combined is already attached' do
    call.recording.attach(io: StringIO.new('combined'), filename: 'combined.ogg', content_type: 'audio/ogg')
    existing = call.recording.blob.id

    ready_callback

    expect(response).to have_http_status(:ok)
    expect(Whatsapp::CallRecordingFetchJob).to have_received(:perform_later).with(call.id)
    expect(call.reload.recording.blob.id).to eq(existing)
    expect(call.meta.dig('recording_bundle', 'expected_sha256')).to eq(digest)
    expect(call.meta.dig('recording_bundle', 'completed_sha256')).to be_nil
  end

  it 'lets repeated callbacks retry an unfinished import' do
    2.times { ready_callback }

    expect(Whatsapp::CallRecordingFetchJob).to have_received(:perform_later).with(call.id).twice
    expect(call.reload.meta.dig('recording_bundle', 'completed_sha256')).to be_nil
  end

  it 'deduplicates only a completed digest with its manifest attached' do
    call.recording_manifest.attach(io: StringIO.new('{}'), filename: 'manifest.json', content_type: 'application/json')
    call.update!(meta: { 'recording_bundle' => { 'version' => 1, 'expected_sha256' => digest, 'completed_sha256' => digest } })

    ready_callback

    expect(response).to have_http_status(:ok)
    expect(Whatsapp::CallRecordingFetchJob).not_to have_received(:perform_later)
  end

  it 'repairs a completed marker whose manifest attachment is missing' do
    call.update!(meta: { 'recording_bundle' => { 'version' => 1, 'expected_sha256' => digest, 'completed_sha256' => digest } })

    ready_callback

    expect(Whatsapp::CallRecordingFetchJob).to have_received(:perform_later).with(call.id)
  end

  it 'does not replace a completed immutable bundle digest' do
    call.update!(meta: { 'recording_bundle' => { 'version' => 1, 'expected_sha256' => digest, 'completed_sha256' => digest } })

    ready_callback(payload.merge(recording_manifest_sha256: 'b' * 64))

    expect(response).to have_http_status(:conflict)
    expect(call.reload.meta.dig('recording_bundle', 'expected_sha256')).to eq(digest)
    expect(Whatsapp::CallRecordingFetchJob).not_to have_received(:perform_later)
  end

  it 'binds an initially blank session only through the matching account and provider call' do
    call.update!(media_session_id: nil)

    ready_callback(payload.merge(session_id: 'session_bound'))

    expect(response).to have_http_status(:ok)
    expect(call.reload.media_session_id).to eq('session_bound')
  end

  it 'rejects a different session for an already bound provider call' do
    ready_callback(payload.merge(session_id: 'foreign_session'))

    expect(response).to have_http_status(:conflict)
    expect(call.reload.media_session_id).to eq('session_test')
    expect(call.meta['recording_bundle']).to be_nil
    expect(Whatsapp::CallRecordingFetchJob).not_to have_received(:perform_later)
  end

  %i[account_id call_id].each do |field|
    it "rejects a foreign #{field} without binding or updating the call" do
      before_meta = call.meta
      ready_callback(payload.merge(field => 'foreign'))

      expect(response).to have_http_status(:not_found)
      expect(call.reload.meta).to eq(before_meta)
      expect(Whatsapp::CallRecordingFetchJob).not_to have_received(:perform_later)
    end
  end

  %i[account_id provider_call_id].each do |field|
    it "rechecks #{field} under lock if identity changed after lookup" do
      request_payload = payload
      before_meta = call.meta
      replacement = field == :account_id ? create(:account).id : 'changed_provider_call'
      allow(Call).to receive(:find_by).and_wrap_original do |original, *arguments|
        found = original.call(*arguments)
        found.update!(field => replacement) if found&.id == call.id
        found
      end

      ready_callback(request_payload)

      expect(response).to have_http_status(:conflict)
      expect(call.reload.meta).to eq(before_meta)
      expect(call.recording_tracks.count).to eq(0)
      expect(call.recording_manifest).not_to be_attached
      expect(Whatsapp::CallRecordingFetchJob).not_to have_received(:perform_later)
    end
  end

  it 'rejects missing authentication before publishing the expected digest' do
    ready_callback(payload, authenticated: false)

    expect(response).to have_http_status(:unauthorized)
    expect(call.reload.meta['recording_bundle']).to be_nil
  end

  it 'rejects an unknown version and malformed digest' do
    ready_callback(payload.merge(recording_manifest_version: 2))
    expect(response).to have_http_status(:unprocessable_entity)
    ready_callback(payload.merge(recording_manifest_sha256: 'bad'))
    expect(response).to have_http_status(:bad_request)
    expect(call.reload.meta['recording_bundle']).to be_nil
  end

  it 'keeps a ready signal retryable after enqueue raises' do
    allow(Whatsapp::CallRecordingFetchJob).to receive(:perform_later).and_raise('synthetic queue failure')
    ready_callback
    expect(response).to have_http_status(:internal_server_error)
    allow(Whatsapp::CallRecordingFetchJob).to receive(:perform_later).and_return(true)

    ready_callback

    expect(response).to have_http_status(:ok)
    expect(call.reload.meta.dig('recording_bundle', 'expected_sha256')).to eq(digest)
    expect(call.meta.dig('recording_bundle', 'completed_sha256')).to be_nil
  end
end
