require 'rails_helper'

RSpec.describe Telephony::CallRecordingTranscriptionService, type: :service do
  let(:account) do
    create(
      :account,
      captain_features: { 'audio_transcription' => true },
      audio_transcriptions: false
    ).tap { |record| record.enable_features!('captain_integration') }
  end
  let(:conversation) { create(:conversation, account: account) }
  let(:voice_message) do
    create(
      :message,
      account: account,
      conversation: conversation,
      inbox: conversation.inbox,
      content_type: :voice_call,
      source_id: 'voice_call:operator-call-1',
      content_attributes: { 'data' => { 'status' => 'completed' } }
    )
  end
  let(:call_session) do
    create(
      :telephony_call_session,
      account: account,
      conversation: conversation,
      inbox: conversation.inbox,
      external_call_ref: 'operator-call-1',
      status: 'completed',
      direction: 'inbound',
      recording_ref: 'rec_operator_1',
      metadata: {
        'recording' => {
          'recording_ref' => 'rec_operator_1',
          'storage_key' => 'voice-recordings/1/operator-call-1/recording.wav',
          'content_type' => 'audio/wav',
          'source' => 'onelink_runtime'
        },
        'metadata' => { 'routing_mode' => 'operator' }
      }
    )
  end
  let(:transcript) { 'Клиент: Алло\nОператор: Здравствуйте' }
  let(:recording_path) { Rails.root.join('storage/voice-recordings/1/operator-call-1/recording.wav') }
  let(:response) { described_class::TranscriptionResult.new(text: transcript) }

  before do
    voice_message
    FileUtils.mkdir_p(recording_path.dirname)
    File.binwrite(recording_path, "RIFF\x24\x00\x00\x00WAVEfmt ")
    allow(Llm::Config).to receive(:provider_for_model).and_return('openai')
    allow(Llm::Config).to receive(:api_key).and_return('test-key')
    allow(Llm::Config).to receive(:api_base).and_return(nil)
    allow(Llm::Config).to receive(:with_api_key).and_yield(:llm_context)
    allow(Llm::ApiClient).to receive(:transcribe).and_return(response)
  end

  after do
    FileUtils.rm_f(recording_path)
  end

  it 'transcribes a stored call recording into the native voice call bubble' do
    result = described_class.new(call_session).perform

    expect(result).to include(success: true, transcript: transcript)
    expect(Llm::ApiClient).to have_received(:transcribe).with(
      recording_path.to_s,
      hash_including(context: :llm_context, model: anything, temperature: 0.2)
    )

    call_session.reload
    expect(call_session.transcript_ref).to eq('call_recording_transcript:operator-call-1')
    expect(call_session.metadata.dig('recording', 'transcription', 'status')).to eq('completed')
    expect(call_session.metadata.dig('recording', 'transcription', 'text')).to eq(transcript)

    data = voice_message.reload.content_attributes['data']
    expect(data['transcript_ref']).to eq('call_recording_transcript:operator-call-1')
    expect(data['transcript']).to eq(transcript)
    expect(data['recording']).to include('storage_key' => 'voice-recordings/1/operator-call-1/recording.wav')
  end

  it 'does not attach a recording transcript to a newer unsourced legacy voice_call when exact bubble exists' do
    legacy_voice_message = create(
      :message,
      account: account,
      conversation: conversation,
      inbox: conversation.inbox,
      content_type: :voice_call,
      content_attributes: { 'data' => { 'status' => 'completed' } }
    )

    described_class.new(call_session).perform

    expect(voice_message.reload.content_attributes.dig('data', 'transcript_ref')).to eq('call_recording_transcript:operator-call-1')
    expect(legacy_voice_message.reload.content_attributes.dig('data', 'transcript_ref')).to be_blank
    expect(legacy_voice_message.content_attributes.dig('data', 'transcript')).to be_blank
  end

  it 'rejects recording storage keys that resolve through symlinks outside storage' do
    outside_path = Rails.root.join('tmp/operator-call-secret.wav')
    FileUtils.rm_f(recording_path)
    File.binwrite(outside_path, "RIFF\x24\x00\x00\x00WAVEfmt ")
    FileUtils.ln_s(outside_path, recording_path)

    expect { described_class.new(call_session).perform }.to raise_error(described_class::RecordingNotFound)
    expect(Llm::ApiClient).not_to have_received(:transcribe)
  ensure
    FileUtils.rm_f(outside_path) if defined?(outside_path) && outside_path.present?
  end
end
