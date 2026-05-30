require 'rails_helper'

RSpec.describe Messages::AudioTranscriptionService, type: :service do
  let(:account) do
    create(
      :account,
      audio_transcriptions: false,
      captain_features: { 'audio_transcription' => true },
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

      it 'returns transcription limit exceeded' do
        expect(service.perform).to eq({ error: 'Transcription limit exceeded' })
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

    context 'when captain audio transcription feature is disabled' do
      before do
        account.update!(captain_features: { 'audio_transcription' => false }, audio_transcriptions: true)
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

    it 'uses RubyLLM transcription through the shared API client for legacy direct provider models' do
      allow(service).to receive(:model).and_return('gpt-4o-transcribe')
      allow(Llm::Config).to receive(:provider_for_model).with('gpt-4o-transcribe', account: account).and_return('openai')

      expect(Llm::ApiClient).to receive(:transcribe).with(
        instance_of(String),
        context: mock_context,
        model: 'gpt-4o-transcribe',
        prompt: 'Transcribe Kazakh and Russian accurately.',
        temperature: 0.4,
        observability: hash_including(
          runtime_mode: 'audio_transcription',
          feature_name: 'audio_transcription',
          account_id: service.account.id
        )
      ).and_return(mock_transcription)

      expect(service.send(:transcribe_audio)).to eq('Hello world transcription')
      expect(attachment.reload.meta).to eq({ 'transcribed_text' => 'Hello world transcription' })
    end

    it 'uses the cached transcription when already present' do
      attachment.update!(meta: { transcribed_text: 'Existing transcription' })

      expect(Llm::ApiClient).not_to receive(:transcribe)

      expect(service.send(:transcribe_audio)).to eq('Existing transcription')
    end

    it 'uses OpenRouter chat audio input when an OpenRouter audio model is selected' do
      chat = instance_double(RubyLLM::Chat)
      response = instance_double(RubyLLM::Message, content: 'OpenRouter transcription')

      allow(service).to receive(:model).and_return('openai/gpt-audio-mini')
      allow(Llm::Config).to receive(:provider_for_model).with('openai/gpt-audio-mini', account: account).and_return('openrouter')
      allow(Llm::Models).to receive(:supports_audio_input?).with('openai/gpt-audio-mini', account: account).and_return(true)
      allow(service).to receive(:chat).with(model: 'openai/gpt-audio-mini', temperature: 0).and_return(chat)

      expect(Llm::ApiClient).not_to receive(:transcribe)
      expect(Open3).not_to receive(:capture3)
      expect(Llm::ChatClient).to receive(:ask) do |received_chat, content, observability:, account:|
        expect(received_chat).to eq(chat)
        expect(account).to eq(service.account)
        expect(content).to be_a(RubyLLM::Content)
        expect(content.text).to include('Transcribe the attached audio accurately')
        expect(content.attachments.first.type).to eq(:audio)
        expect(observability).to include(runtime_mode: 'audio_transcription', provider: 'openrouter')
        response
      end

      expect(service.send(:transcribe_audio)).to eq('OpenRouter transcription')
      expect(attachment.reload.meta).to eq({ 'transcribed_text' => 'OpenRouter transcription' })
    end

    it 'normalizes Ogg Opus audio to WAV before sending it to OpenRouter audio input models' do
      chat = instance_double(RubyLLM::Chat)
      response = instance_double(RubyLLM::Message, content: 'OpenRouter Opus transcription')

      attachment.file.detach
      attachment.file.attach(
        io: StringIO.new('OggSfake-opus-data'),
        filename: 'voice-message',
        content_type: 'audio/opus'
      )
      allow(service).to receive(:model).and_return('openai/gpt-audio-mini')
      allow(Llm::Config).to receive(:provider_for_model).with('openai/gpt-audio-mini', account: account).and_return('openrouter')
      allow(Llm::Models).to receive(:supports_audio_input?).with('openai/gpt-audio-mini', account: account).and_return(true)
      allow(service).to receive(:chat).with(model: 'openai/gpt-audio-mini', temperature: 0).and_return(chat)
      allow(Llm::OpenRouterAudioInput).to receive(:ffmpeg_path).and_return('/usr/bin/ffmpeg')

      expect(Open3).to receive(:capture3) do |*args|
        destination_file_path = args.last
        expect(args).to include('/usr/bin/ffmpeg', '-i')
        expect(destination_file_path).to end_with('.openrouter.wav')
        File.binwrite(destination_file_path, 'RIFFfake-wav-data')
        ['', '', instance_double(Process::Status, success?: true)]
      end
      expect(Llm::ChatClient).to receive(:ask) do |_received_chat, content, observability:, account:|
        expect(account).to eq(service.account)
        expect(content.attachments.first.type).to eq(:audio)
        expect(content.attachments.first.format).to eq('wav')
        expect(content.attachments.first.source.to_s).to end_with('.openrouter.wav')
        expect(observability).to include(runtime_mode: 'audio_transcription', provider: 'openrouter')
        response
      end

      expect(service.send(:transcribe_audio)).to eq('OpenRouter Opus transcription')
      expect(attachment.reload.meta).to eq({ 'transcribed_text' => 'OpenRouter Opus transcription' })
    end

    it 'uses the native OpenRouter transcription endpoint for dedicated STT models' do
      transcription = RubyLLM::Transcription.new(text: 'OpenRouter STT transcription', model: 'openai/gpt-4o-mini-transcribe')

      allow(service).to receive(:model).and_return('openai/gpt-4o-mini-transcribe')
      allow(Llm::Config).to receive(:provider_for_model).with('openai/gpt-4o-mini-transcribe', account: account).and_return('openrouter')
      allow(Llm::Models).to receive(:type_for).with('openai/gpt-4o-mini-transcribe', account: account).and_return('transcription')
      allow(Llm::Config).to receive(:api_key).with('openrouter', account: account).and_return('openrouter-key')
      allow(Llm::Config).to receive(:api_base).with('openrouter', account: account).and_return('https://openrouter.ai/api/v1')

      expect(Llm::ChatClient).not_to receive(:ask)
      expect(Llm::ApiClient).to receive(:transcribe).with(
        instance_of(String),
        provider: 'openrouter',
        api_key: 'openrouter-key',
        api_base: 'https://openrouter.ai/api/v1',
        model: 'openai/gpt-4o-mini-transcribe',
        temperature: 0.4,
        observability: hash_including(runtime_mode: 'audio_transcription', provider: 'openrouter')
      ).and_return(transcription)

      expect(service.send(:transcribe_audio)).to eq('OpenRouter STT transcription')
      expect(attachment.reload.meta).to eq({ 'transcribed_text' => 'OpenRouter STT transcription' })
    end
  end
end
