require 'rails_helper'

# The request OpenRouter really receives for a voice message. Only the outgoing HTTP call is stubbed: the service, Llm::Runtime, the
# OpenRouter runtime and the HTTP clients run as they do in production, so a prompt or a temperature that is lost on the way
# fails here. (The unit specs of the service stub Llm::Runtime and cannot see that.)
RSpec.describe Messages::AudioTranscriptionService, '#transcribe_audio', type: :service do
  let(:api_base) { 'https://openrouter.example/api/v1' }
  let(:workspace_runtime) { {} }
  let(:account) { create(:account, audio_transcriptions: true, captain_runtime: workspace_runtime) }
  let(:message) { create(:message, conversation: create(:conversation, account: account)) }
  let(:attachment) { message.attachments.create!(account: account, file_type: :audio) }
  let(:service) { described_class.new(attachment) }
  let(:context_sample) { Messages::AudioTranscriptionPrompt::CONTEXT_SAMPLE }
  let(:sent) { [] }

  before do
    attachment.file.attach(
      io: File.open(Rails.public_path.join('audio/widget/ding.mp3')),
      filename: 'speech.mp3',
      content_type: 'audio/mpeg'
    )
    allow(Llm::Config).to receive(:api_key).and_call_original
    allow(Llm::Config).to receive(:api_key).with('openrouter', account: account).and_return('openrouter-key')
    allow(Llm::Config).to receive(:api_base).and_call_original
    allow(Llm::Config).to receive(:api_base).with('openrouter', account: account).and_return(api_base)
    allow(Llm::Config).to receive(:provider_for_model).and_call_original
    allow(Llm::Config).to receive(:provider_for_model).with(model, account: account).and_return('openrouter')
    allow(Llm::Models).to receive(:type_for).and_call_original
    allow(Llm::Models).to receive(:type_for).with(model, account: account).and_return(model_type)
    allow(service).to receive(:model).and_return(model)
  end

  context 'with a dedicated transcription model on the native transcription endpoint' do
    let(:model) { 'openai/gpt-4o-mini-transcribe' }
    let(:model_type) { 'transcription' }
    let(:body) { sent.fetch(0) }

    before do
      stub_request(:post, "#{api_base}/audio/transcriptions")
        .with { |http_request| sent << JSON.parse(http_request.body) }
        .to_return(status: 200, body: { text: 'Сәлеметсіз бе, ертең бос уақыт бар ма?' }.to_json, headers: { 'Content-Type' => 'application/json' })
    end

    context 'when the workspace has no transcription prompt' do
      it 'sends the built-in context as provider.options.openai.prompt at temperature 0 and no language', :aggregate_failures do
        expect(service.send(:transcribe_audio)).to eq('Сәлеметсіз бе, ертең бос уақыт бар ма?')

        expect(sent.size).to eq(1)
        expect(body).to include('model' => 'openai/gpt-4o-mini-transcribe', 'temperature' => 0)
        expect(body.dig('provider', 'options')).to eq('openai' => { 'prompt' => context_sample })
        expect(body).not_to have_key('language')
        expect(body).not_to have_key('prompt')
        expect(body.dig('input_audio', 'format')).to eq('mp3')
      end
    end

    context 'when the workspace has its own transcription prompt' do
      let(:workspace_runtime) { { 'audio_transcription_prompt' => 'Клиника ЛОР, Алматы.' } }

      it 'sends the workspace prompt instead of the built-in context', :aggregate_failures do
        service.send(:transcribe_audio)

        expect(body['temperature']).to eq(0)
        expect(body.dig('provider', 'options')).to eq('openai' => { 'prompt' => 'Клиника ЛОР, Алматы.' })
        expect(body.to_json).not_to include(context_sample)
      end
    end

    it 'sends the same prompt for gpt-4o-transcribe, the model the owner chose as the default', :aggregate_failures do
      allow(service).to receive(:model).and_return('openai/gpt-4o-transcribe')
      allow(Llm::Config).to receive(:provider_for_model).with('openai/gpt-4o-transcribe', account: account).and_return('openrouter')
      allow(Llm::Models).to receive(:type_for).with('openai/gpt-4o-transcribe', account: account).and_return('transcription')

      service.send(:transcribe_audio)

      expect(body).to include('model' => 'openai/gpt-4o-transcribe', 'temperature' => 0)
      expect(body.dig('provider', 'options')).to eq('openai' => { 'prompt' => context_sample })
    end

    it 'does not store the built-in context when the model repeats it for a silent clip' do
      stub_request(:post, "#{api_base}/audio/transcriptions")
        .to_return(status: 200, body: { text: context_sample }.to_json, headers: { 'Content-Type' => 'application/json' })

      expect(service.send(:transcribe_audio)).to eq('')
      expect(attachment.reload.meta).to be_blank
    end
  end

  context 'with an audio chat model that hears the voice message in a chat request' do
    let(:model) { 'openai/gpt-audio-mini' }
    let(:model_type) { 'chat' }
    let(:model_config) do
      {
        'provider' => 'openrouter', 'type' => 'chat', 'capabilities' => %w[audio_input],
        'supported_parameters' => %w[temperature]
      }
    end
    let(:body) { sent.fetch(0) }
    let(:user_message) { body['messages'].find { |entry| entry['role'] == 'user' } }
    let(:user_parts) { user_message['content'] }

    before do
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(model => model_config)
      allow(Llm::Config).to receive(:provider_available?) { |provider, **| provider == 'openrouter' }
      allow(Llm::Models).to receive(:model_config).and_call_original
      allow(Llm::Models).to receive(:model_config).with(model, account: account).and_return(model_config)
      allow(Llm::Models).to receive(:supports_audio_input?).and_call_original
      allow(Llm::Models).to receive(:supports_audio_input?).with(model, account: account).and_return(true)
      stub_request(:post, "#{api_base}/chat/completions")
        .with { |http_request| sent << JSON.parse(http_request.body) }
        .to_return(
          status: 200,
          headers: { 'Content-Type' => 'application/json' },
          body: {
            id: 'gen-1', model: model, usage: { prompt_tokens: 10, completion_tokens: 5 },
            choices: [{ index: 0, finish_reason: 'stop', message: { role: 'assistant', content: 'Сәлеметсіз бе' } }]
          }.to_json
        )
    end

    context 'when the workspace has no transcription prompt' do
      it 'sends the audio with the Kazakh instruction at temperature 0', :aggregate_failures do
        expect(service.send(:transcribe_audio)).to eq('Сәлеметсіз бе')

        expect(sent.size).to eq(1)
        expect(body).to include('model' => model, 'temperature' => 0)
        text = user_parts.select { |part| part['type'] == 'text' }.pluck('text').join("\n")
        expect(text).to eq("#{Messages::AudioTranscriptionPrompt::CHAT_INSTRUCTION}\n#{Messages::AudioTranscriptionPrompt::CHAT_LANGUAGE_HINT}")
        expect(user_parts.map { |part| part['type'] }).to include('input_audio')
      end
    end

    context 'when the workspace has its own transcription prompt' do
      let(:workspace_runtime) { { 'audio_transcription_prompt' => 'Клиника ЛОР, Алматы.' } }

      it 'sends the workspace prompt instead of the built-in instruction', :aggregate_failures do
        service.send(:transcribe_audio)

        text = user_parts.select { |part| part['type'] == 'text' }.pluck('text').join("\n")
        expect(body['temperature']).to eq(0)
        expect(text).to include('Клиника ЛОР, Алматы.')
        expect(text).not_to include('Kyrgyz')
      end
    end
  end
end
