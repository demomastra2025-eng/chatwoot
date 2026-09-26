require 'rails_helper'

RSpec.describe Whatsapp::CallTranscriptionService, type: :service do
  let(:account) { create(:account, call_transcriptions: true) }
  let(:call) { create(:call, account: account) }
  let(:service) { described_class.new(call) }

  before do
    call.recording.attach(io: StringIO.new('OggSshort-test'), filename: 'call.ogg', content_type: 'audio/ogg')
    allow(account).to receive(:captain_quota_available?).and_return(true)
    allow(service).to receive(:instrument_audio_transcription).and_yield
  end

  it 'uses pinned native STT for the combined recording despite legacy override, without catalog scanning' do
    account.update!(captain_models: { 'audio_transcription' => 'openai/gpt-audio-mini' })
    transcription = RubyLLM::Transcription.new(text: 'Hello from a call', model: 'openai/gpt-4o-transcribe')

    expect(Llm::Models).not_to receive(:models_for)
    expect(Llm::OpenRouterModelCatalog).not_to receive(:model_configs)
    expect(Llm::OpenRouterEndpointCatalog).not_to receive(:endpoint_configs)
    expect(Llm::Runtime).not_to receive(:chat)
    expect(Llm::Runtime).to receive(:transcribe) do |**kwargs|
      expect(kwargs).to include(feature: :audio_transcription, account: account, model: 'openai/gpt-4o-transcribe')
      expect(File.extname(kwargs[:input])).to eq('.ogg')
      expect(kwargs[:options]).to include(stage_timings: an_instance_of(Llm::TranscriptionTimings))
      transcription
    end

    expect(service.perform).to include(success: true, transcript: 'Hello from a call')
    expect(call.reload.transcript).to eq('Hello from a call')
  end

  it 'removes the temporary combined recording if normalization fails' do
    allow(Llm::OpenRouterAudioInput).to receive(:normalize_for_transcription)
      .and_raise(Llm::OpenRouterAudioInput::NormalizationError, 'invalid audio')
    expect(FileUtils).to receive(:rm_f).with(match(%r{tmp/uploads/call-transcriptions/})).and_call_original
    expect(Llm::Runtime).not_to receive(:transcribe)

    expect { service.perform }.to raise_error(Llm::OpenRouterAudioInput::NormalizationError)
  end
end
