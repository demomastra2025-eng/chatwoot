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
    # Create required installation configs
    InstallationConfig.find_or_create_by!(name: 'CAPTAIN_OPEN_AI_API_KEY') { |config| config.value = 'test-api-key' }

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

    it 'uses RubyLLM transcription through the shared API client' do
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
  end
end
