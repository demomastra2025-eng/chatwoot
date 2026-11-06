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

  describe 'selected DEV VoiceCore provider' do
    let(:service) { described_class.new(attachment) }
    let(:adapter) { instance_double(Messages::VoiceCoreAttachmentTranscription) }
    let(:local_result) do
      { 'text' => 'Синтетическое голосовое сообщение',
        'provenance' => { 'provider' => 'voicecore', 'model' => Telephony::VoiceCoreClient::APPROVED_MANIFEST_SHA256 } }
    end

    before do
      attachment.file.attach(io: StringIO.new('OggSsynthetic'), filename: 'synthetic-voice', content_type: 'audio/opus')
      allow(Telephony::VoiceCoreClient).to receive(:selected_for?).with(service.account).and_return(true)
      allow(Messages::VoiceCoreAttachmentTranscription).to receive(:new).with(attachment).and_return(adapter)
      allow(adapter).to receive(:perform).and_return(local_result)
      allow(service.account).to receive(:captain_quota_available?).and_return(true)
      allow(service.account).to receive(:increment_response_usage)
      allow(service.message).to receive(:account).and_return(service.account)
      allow(service.message).to receive(:send_update_event)
      allow(Contacts::LanguageStatsService).to receive(:refresh!)
      allow(ChatwootApp).to receive(:advanced_search_allowed?).and_return(false)
      allow(Llm::Runtime).to receive(:transcribe)
      allow(Llm::Runtime).to receive(:chat)
      allow(service).to receive(:fetch_audio_file)
      allow(Compliance::ExplicitAiConsentGate).to receive(:blocked?).and_return(false)
    end

    it 'stores local provenance alongside the text and preserves existing attachment metadata' do
      attachment.update!(meta: { 'synthetic_marker' => 'preserve', 'transcription' => { 'synthetic_extra' => true } })
      expect(service.perform).to eq(success: true, transcriptions: local_result['text'])
      expect(attachment.reload.meta).to include('synthetic_marker' => 'preserve', 'transcribed_text' => local_result['text'])
      expect(attachment.meta['transcription']).to include(local_result['provenance'].merge('synthetic_extra' => true))
      expect(service.account).to have_received(:increment_response_usage).once
      expect(service.message).to have_received(:send_update_event)
      expect(Contacts::LanguageStatsService).to have_received(:refresh!)
    end

    it 'returns the native cache without another local inference or usage increment' do
      service.perform
      expect(service.perform).to eq(success: true, transcriptions: local_result['text'])
      expect(adapter).to have_received(:perform).once
      expect(service.account).to have_received(:increment_response_usage).once
    end

    it 'bypasses cloud download, conversion and paid transcription or enrichment' do
      service.perform
      expect(service).not_to have_received(:fetch_audio_file)
      expect(Llm::Runtime).not_to have_received(:transcribe)
      expect(Llm::Runtime).not_to have_received(:chat)
    end

    it 'preserves explicit AI consent before local inference and storage' do
      allow(Compliance::ExplicitAiConsentGate).to receive(:blocked?).and_return(true)
      expect(service.perform).to eq(error: 'AI consent required')
      expect(adapter).not_to have_received(:perform)
      expect(attachment.reload.meta).to be_blank
      expect(service.account).not_to have_received(:increment_response_usage)
    end

    it 'preserves both the audio enabled flag and native quota before local inference' do
      allow(service.account).to receive(:audio_transcriptions_enabled?).and_return(false)
      expect(service.perform).to eq(error: 'Transcription limit exceeded')
      allow(service.account).to receive(:audio_transcriptions_enabled?).and_return(true)
      allow(service.account).to receive(:captain_quota_available?).and_return(false)
      expect(service.perform).to eq(error: 'Transcription limit exceeded')
      expect(adapter).not_to have_received(:perform)
    end

    it 'keeps local failures fixed and retryable when appropriate without paid fallback or usage' do
      allow(adapter).to receive(:perform).and_raise(Telephony::VoiceCoreClient::Error.new('unavailable', retryable: true))
      expect(service.perform).to eq(error: 'VoiceCore transcription unavailable', error_code: 'unavailable', retryable: true)
      expect(attachment.reload.meta).to be_blank
      expect(service.account).not_to have_received(:increment_response_usage)
      expect(Llm::Runtime).not_to have_received(:transcribe)
      expect(Llm::Runtime).not_to have_received(:chat)
    end

    it 'retains the native behavior of storing and charging nothing for an empty transcript' do
      allow(adapter).to receive(:perform).and_return(local_result.merge('text' => ''))
      expect(service.perform).to eq(success: true, transcriptions: '')
      expect(attachment.reload.meta).to be_blank
      expect(service.account).not_to have_received(:increment_response_usage)
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

    it 'routes dedicated STT models through the LLM runtime facade' do
      transcription = RubyLLM::Transcription.new(text: 'Hello world transcription', model: 'openai/gpt-4o-transcribe')

      allow(service).to receive(:model).and_return('gpt-4o-transcribe')
      allow(Llm::Config).to receive(:provider_for_model).with('gpt-4o-transcribe', account: account).and_return('openai')

      expect(Llm::ApiClient).not_to receive(:transcribe)
      expect(Llm::Runtime).to receive(:transcribe) do |**kwargs|
        expect(kwargs).to include(
          feature: :audio_transcription,
          account: service.account,
          model: 'gpt-4o-transcribe',
          input: instance_of(String),
          options: { temperature: 0, prompt: 'Transcribe Kazakh and Russian accurately.' }
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

    it 'uses OpenRouter chat audio input when an OpenRouter audio model is selected', :aggregate_failures do
      response = instance_double(RubyLLM::Message, content: 'OpenRouter transcription')

      allow(service).to receive(:model).and_return('openai/gpt-audio-mini')
      allow(Llm::Config).to receive(:provider_for_model).with('openai/gpt-audio-mini', account: account).and_return('openrouter')
      allow(Llm::Models).to receive(:supports_audio_input?).with('openai/gpt-audio-mini', account: account).and_return(true)

      expect(Llm::ApiClient).not_to receive(:transcribe)
      expect(Llm::ChatClient).not_to receive(:ask)
      expect(Open3).not_to receive(:capture3)
      expect(Llm::Runtime).to receive(:chat) do |**kwargs|
        expect(kwargs).to include(
          feature: :audio_transcription,
          account: service.account,
          model: 'openai/gpt-audio-mini',
          options: { temperature: 0 }
        )
        content = kwargs.dig(:messages, 0, :content)
        expect(content).to be_a(RubyLLM::Content)
        expect(content.text).to include('Transcribe the attached audio accurately', 'Transcribe Kazakh and Russian accurately.')
        expect(content.text).not_to include(Messages::AudioTranscriptionPrompt::CHAT_LANGUAGE_HINT)
        expect(content.attachments.first.type).to eq(:audio)
        expect(kwargs[:observability]).to include(runtime_mode: 'audio_transcription', provider: 'openrouter')
        response
      end

      expect(service.send(:transcribe_audio)).to eq('OpenRouter transcription')
      expect(attachment.reload.meta).to eq({ 'transcribed_text' => 'OpenRouter transcription' })
    end

    it 'normalizes Ogg Opus audio to WAV before sending it to OpenRouter audio input models', :aggregate_failures do
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
      allow(Llm::OpenRouterAudioInput).to receive(:ffmpeg_path).and_return('/usr/bin/ffmpeg')

      expect(Telephony::CallTranscript).to receive(:probe).with(a_string_ending_with('.ogg')).and_return({})
      expect(Open3).to receive(:capture3) do |*args|
        destination_file_path = args.last
        expect(args).to include('/usr/bin/ffmpeg', '-i')
        expect(destination_file_path).to end_with('.openrouter.wav')
        File.binwrite(destination_file_path, 'RIFFfake-wav-data')
        ['', '', instance_double(Process::Status, success?: true)]
      end
      expect(Llm::Runtime).to receive(:chat) do |**kwargs|
        expect(kwargs).to include(account: service.account, model: 'openai/gpt-audio-mini')
        content = kwargs.dig(:messages, 0, :content)
        expect(content.attachments.first.type).to eq(:audio)
        expect(content.attachments.first.format).to eq('wav')
        expect(content.attachments.first.source.to_s).to end_with('.openrouter.wav')
        expect(kwargs[:observability]).to include(runtime_mode: 'audio_transcription', provider: 'openrouter')
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

      expect(Llm::ChatClient).not_to receive(:ask)
      expect(Llm::ApiClient).not_to receive(:transcribe)
      expect(Llm::Runtime).to receive(:transcribe) do |**kwargs|
        expect(kwargs).to include(
          feature: :audio_transcription,
          account: service.account,
          model: 'openai/gpt-4o-mini-transcribe',
          input: instance_of(String),
          options: { temperature: 0, prompt: 'Transcribe Kazakh and Russian accurately.' }
        )
        expect(kwargs[:observability]).to include(runtime_mode: 'audio_transcription', provider: 'openrouter')
        transcription
      end

      expect(service.send(:transcribe_audio)).to eq('OpenRouter STT transcription')
      expect(attachment.reload.meta).to eq({ 'transcribed_text' => 'OpenRouter STT transcription' })
    end

    context 'when the workspace has no transcription prompt' do
      let(:context_sample) { Messages::AudioTranscriptionPrompt::CONTEXT_SAMPLE }

      before do
        account.update!(captain_runtime: {})
        allow(Llm::Models).to receive(:type_for).and_call_original
      end

      def stub_transcription_endpoint(text)
        allow(service).to receive(:model).and_return('openai/gpt-4o-mini-transcribe')
        allow(Llm::Config).to receive(:provider_for_model).with('openai/gpt-4o-mini-transcribe', account: account).and_return('openrouter')
        allow(Llm::Models).to receive(:type_for).with('openai/gpt-4o-mini-transcribe', account: account).and_return('transcription')
        allow(Llm::Runtime).to receive(:transcribe).and_return(RubyLLM::Transcription.new(text: text, model: 'openai/gpt-4o-mini-transcribe'))
      end

      it 'sends the built-in Kazakh and Russian context at temperature 0 and leaves the language to the model' do
        stub_transcription_endpoint('Сәлеметсіз бе, ертеңге жазылуға бола ма?')

        expect(service.send(:transcribe_audio)).to eq('Сәлеметсіз бе, ертеңге жазылуға бола ма?')
        expect(Llm::Runtime).to have_received(:transcribe).with(
          hash_including(options: { temperature: 0, prompt: context_sample })
        )
      end

      it 'drops the built-in context when the model returns it with the transcript' do
        stub_transcription_endpoint("#{context_sample} Ертеңге жазылуға бола ма?")

        expect(service.send(:transcribe_audio)).to eq('Ертеңге жазылуға бола ма?')
        expect(attachment.reload.meta).to eq({ 'transcribed_text' => 'Ертеңге жазылуға бола ма?' })
      end

      it 'stores nothing when the model returns only the built-in context' do
        stub_transcription_endpoint(context_sample)

        expect(service.send(:transcribe_audio)).to eq('')
        expect(attachment.reload.meta).to be_blank
      end

      it 'tells a chat audio model the same in words' do
        allow(service).to receive(:model).and_return('openai/gpt-audio-mini')
        allow(Llm::Config).to receive(:provider_for_model).with('openai/gpt-audio-mini', account: account).and_return('openrouter')
        allow(Llm::Models).to receive(:type_for).with('openai/gpt-audio-mini', account: account).and_return('chat')
        allow(Llm::Models).to receive(:supports_audio_input?).with('openai/gpt-audio-mini', account: account).and_return(true)
        allow(Llm::Runtime).to receive(:chat).and_return(instance_double(RubyLLM::Message, content: 'Сәлеметсіз бе'))

        expect(service.send(:transcribe_audio)).to eq('Сәлеметсіз бе')
        expect(Llm::Runtime).to have_received(:chat) do |**kwargs|
          expect(kwargs[:options]).to eq({ temperature: 0 })
          expect(kwargs.dig(:messages, 0, :content).text).to eq(
            "#{Messages::AudioTranscriptionPrompt::CHAT_INSTRUCTION}
#{Messages::AudioTranscriptionPrompt::CHAT_LANGUAGE_HINT}"
          )
        end
      end
    end
  end
end
