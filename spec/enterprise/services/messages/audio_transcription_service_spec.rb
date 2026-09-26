require 'rails_helper'

RSpec.describe Messages::AudioTranscriptionService, type: :service do
  let(:account) do
    create(
      :account,
      audio_transcriptions: true,
      captain_runtime: { 'audio_transcription_prompt' => 'Transcribe Kazakh and Russian accurately.' }
    )
  end
  let(:conversation) { create(:conversation, account: account) }
  let(:message) { create(:message, conversation: conversation) }
  let(:attachment) { message.attachments.create!(account: account, file_type: :audio) }
  let(:mock_context) { instance_double(RubyLLM::Context) }
  let(:mock_transcription) { instance_double(RubyLLM::Transcription, text: 'Hello world transcription') }

  before do
    upsert_installation_config('CAPTAIN_OPEN_AI_API_KEY', 'test-api-key')
    InstallationConfig.find_by(name: 'CAPTAIN_OPENROUTER_API_KEY')&.destroy!
    InstallationConfig.find_by(name: 'CAPTAIN_DEFAULT_MODEL')&.destroy!
    InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_MODEL')&.destroy!

    # Mock usage limits for transcription to be available
    allow(account).to receive(:usage_limits).and_return({ captain: { responses: { current_available: 100 } } })
  end

  describe '#perform' do
    let(:service) { described_class.new(attachment) }

    context 'when captain_integration feature is not enabled' do
      before do
        account.disable_features!('captain_integration')
      end

      it 'still permits workspace audio transcription' do
        allow(service).to receive(:supported_attachment_format?).and_return(true)
        allow(service).to receive(:transcribe_audio).and_return('Workspace transcript')

        expect(service.perform).to eq({ success: true, transcriptions: 'Workspace transcript' })
      end
    end

    context 'when transcription is successful' do
      before do
        attachment.file.attach(
          io: File.open(Rails.public_path.join('audio/widget/ding.mp3')),
          filename: 'speech.mp3',
          content_type: 'audio/mpeg'
        )
        # Mock can_transcribe? to return true and transcribe_audio method
        allow(service).to receive(:can_transcribe?).and_return(true)
        allow(service).to receive(:transcribe_audio).and_return('Hello world transcription')
      end

      it 'returns successful transcription' do
        result = service.perform
        expect(result).to eq({ success: true, transcriptions: 'Hello world transcription' })
      end
    end

    context 'when workspace audio transcription is disabled' do
      before do
        account.update!(audio_transcriptions: false)
      end

      it 'returns error for transcription limit exceeded' do
        result = service.perform
        expect(result).to eq({ error: 'Transcription limit exceeded' })
      end
    end

    context 'when attachment already has transcribed text' do
      before do
        attachment.update!(meta: { transcribed_text: 'Existing transcription' })
        allow(service).to receive(:can_transcribe?).and_return(true)
      end

      it 'returns existing transcription without calling API' do
        result = service.perform
        expect(result).to eq({ success: true, transcriptions: 'Existing transcription' })
      end
    end

    context 'when WhatsApp Web sends audio/opus without an extension' do
      before do
        allow(service).to receive(:can_transcribe?).and_return(true)
        attachment.file.attach(
          io: StringIO.new('OggSfake-opus-data'),
          filename: 'ptt-message',
          content_type: 'audio/opus'
        )
      end

      it 'treats it as an Ogg Opus file and calls the transcription API' do
        expect(service).to receive(:transcribe_audio).and_return('Привет')

        result = service.perform

        expect(result).to eq({ success: true, transcriptions: 'Привет' })
      end
    end

    context 'when the attachment format is not supported' do
      before do
        allow(service).to receive(:can_transcribe?).and_return(true)
        attachment.file.attach(
          io: StringIO.new('plain text'),
          filename: 'speech.txt',
          content_type: 'text/plain'
        )
      end

      it 'skips the transcription without calling the API' do
        expect(service).not_to receive(:transcribe_audio)

        result = service.perform

        expect(result).to eq({ error: 'Unsupported audio format' })
      end
    end
  end

  describe '#fetch_audio_file' do
    let(:service) { described_class.new(attachment) }
    let(:upload_io) { File.open(Rails.public_path.join('audio/widget/ding.mp3')) }
    let(:filename) { 'speech' }
    let(:content_type) { 'audio/mpeg' }

    before do
      attachment.file.attach(
        io: upload_io,
        filename: filename,
        content_type: content_type
      )
    end

    it 'adds extension from content type when filename has no extension' do
      temp_file_path = service.send(:fetch_audio_file)

      expect(File.extname(temp_file_path)).to eq('.mpeg')
    ensure
      FileUtils.rm_f(temp_file_path) if temp_file_path.present?
    end

    context 'when WhatsApp Web stores audio/opus without an extension' do
      let(:upload_io) { StringIO.new('OggSfake-opus-data') }
      let(:filename) { 'ptt-message' }
      let(:content_type) { 'audio/opus' }

      it 'writes a temp file with an ogg extension accepted by the transcription provider' do
        temp_file_path = service.send(:fetch_audio_file)

        expect(File.extname(temp_file_path)).to eq('.ogg')
      ensure
        FileUtils.rm_f(temp_file_path) if temp_file_path.present?
      end
    end
  end

  describe '#transcribe_audio' do
    let(:service) { described_class.new(attachment) }

    before do
      attachment.file.attach(
        io: File.open(Rails.public_path.join('audio/widget/ding.mp3')),
        filename: 'speech.mp3',
        content_type: 'audio/mpeg'
      )
      allow(Llm::Config).to receive(:with_api_key).and_yield(mock_context)
      allow(service).to receive(:instrument_audio_transcription).and_yield
    end

    it 'routes the pinned native STT model through the LLM runtime facade' do
      transcription = RubyLLM::Transcription.new(text: 'Hello world transcription', model: 'openai/gpt-4o-transcribe')

      expect(Llm::ApiClient).not_to receive(:transcribe)
      expect(Llm::Runtime).to receive(:transcribe) do |**kwargs|
        expect(kwargs).to include(
          feature: :audio_transcription,
          account: service.account,
          model: 'openai/gpt-4o-transcribe',
          input: instance_of(String),
          options: include(
            temperature: 0.4, prompt: 'Transcribe Kazakh and Russian accurately.',
            stage_timings: an_instance_of(Llm::TranscriptionTimings)
          )
        )
        expect(kwargs[:observability]).to include(
          runtime_mode: 'audio_transcription',
          provider: 'openrouter',
          feature_name: 'audio_transcription',
          account_id: service.account.id
        )
        transcription
      end

      expect(service.send(:transcribe_audio)).to eq('Hello world transcription')
      expect(attachment.reload.meta).to eq({ 'transcribed_text' => 'Hello world transcription' })
    end

    it 'uses the cached transcription when already present' do
      attachment.update!(meta: { transcribed_text: 'Existing transcription' })

      expect(Llm::ApiClient).not_to receive(:transcribe)

      expect(service.send(:transcribe_audio)).to eq('Existing transcription')
    end

    it 'ignores a saved chat model and never searches the model or endpoint catalogs on a cold cache' do
      account.update!(captain_models: { 'audio_transcription' => 'openai/gpt-audio-mini' })
      response = RubyLLM::Transcription.new(text: 'OpenRouter transcription', model: 'openai/gpt-4o-transcribe')
      expect(Llm::ApiClient).not_to receive(:transcribe)
      expect(Llm::ChatClient).not_to receive(:ask)
      expect(Llm::Runtime).not_to receive(:chat)
      expect(Llm::Models).not_to receive(:models_for)
      expect(Llm::OpenRouterModelCatalog).not_to receive(:model_configs)
      expect(Llm::OpenRouterEndpointCatalog).not_to receive(:endpoint_configs)
      expect(Open3).not_to receive(:capture3)
      expect(Llm::Runtime).to receive(:transcribe) do |**kwargs|
        expect(kwargs).to include(
          feature: :audio_transcription,
          account: service.account,
          model: 'openai/gpt-4o-transcribe',
          options: include(prompt: 'Transcribe Kazakh and Russian accurately.')
        )
        expect(kwargs[:observability]).to include(runtime_mode: 'audio_transcription', provider: 'openrouter')
        response
      end

      expect(service.send(:transcribe_audio)).to eq('OpenRouter transcription')
      expect(attachment.reload.meta).to eq({ 'transcribed_text' => 'OpenRouter transcription' })
    end

    it 'sends Ogg Opus to the native STT endpoint without chat-only transcoding' do
      response = RubyLLM::Transcription.new(text: 'OpenRouter Opus transcription', model: 'openai/gpt-4o-transcribe')

      attachment.file.detach
      attachment.file.attach(
        io: StringIO.new('OggSfake-opus-data'),
        filename: 'voice-message',
        content_type: 'audio/opus'
      )
      expect(Open3).not_to receive(:capture3)
      expect(Llm::Runtime).to receive(:transcribe) do |**kwargs|
        expect(kwargs).to include(account: service.account, model: 'openai/gpt-4o-transcribe')
        expect(kwargs[:input]).not_to end_with('.openrouter.wav')
        expect(kwargs[:observability]).to include(runtime_mode: 'audio_transcription', provider: 'openrouter')
        response
      end

      expect(service.send(:transcribe_audio)).to eq('OpenRouter Opus transcription')
      expect(attachment.reload.meta).to eq({ 'transcribed_text' => 'OpenRouter Opus transcription' })
    end

    it 'removes the temporary recording if file preparation fails before the provider request' do
      allow(Llm::OpenRouterAudioInput).to receive(:normalize_for_transcription)
        .and_raise(Llm::OpenRouterAudioInput::NormalizationError, 'invalid audio')
      expect(FileUtils).to receive(:rm_f).with(match(%r{tmp/uploads/audio-transcriptions/})).and_call_original
      expect(Llm::Runtime).not_to receive(:transcribe)

      expect { service.send(:transcribe_audio) }.to raise_error(Llm::OpenRouterAudioInput::NormalizationError)
    end
  end
end
