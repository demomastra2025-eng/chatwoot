# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::OpenRouterTranscriptionClient do
  let(:audio_path) { Rails.root.join('tmp/openrouter-transcription-test.wav').to_s }

  before do
    File.binwrite(audio_path, "RIFF\x24\x00\x00\x00WAVEfmt ")
  end

  after do
    FileUtils.rm_f(audio_path)
  end

  it 'posts base64 audio to the native OpenRouter transcription endpoint' do
    stub = stub_request(:post, 'https://openrouter.ai/api/v1/audio/transcriptions')
           .with(headers: { 'Authorization' => 'Bearer openrouter-key' }) do |request|
      body = JSON.parse(request.body)
      expect(body).to include(
        'model' => 'openai/gpt-4o-mini-transcribe',
        'temperature' => 0.2
      )
      expect(body['input_audio']).to include(
        'format' => 'wav',
        'data' => Base64.strict_encode64(File.binread(audio_path))
      )
    end.to_return(
      status: 200,
      body: {
        text: 'Привет',
        language: 'ru',
        usage: { input_tokens: 12, output_tokens: 3, seconds: 1.4 }
      }.to_json,
      headers: { 'Content-Type' => 'application/json' }
    )

    result = described_class.transcribe(
      audio_path,
      model: 'openai/gpt-4o-mini-transcribe',
      api_key: 'openrouter-key',
      api_base: 'https://openrouter.ai/api/v1',
      temperature: 0.2
    )

    expect(stub).to have_been_requested
    expect(result).to be_a(RubyLLM::Transcription)
    expect(result.text).to eq('Привет')
    expect(result.model).to eq('openai/gpt-4o-mini-transcribe')
    expect(result.input_tokens).to eq(12)
    expect(result.output_tokens).to eq(3)
    expect(result.duration).to eq(1.4)
  end

  describe 'the request body' do
    let(:endpoint) { 'https://openrouter.ai/api/v1/audio/transcriptions' }
    let(:sent) { [] }

    before do
      stub_request(:post, endpoint)
        .with { |request| sent << JSON.parse(request.body) }
        .to_return(status: 200, body: { text: 'Сәлеметсіз бе' }.to_json, headers: { 'Content-Type' => 'application/json' })
    end

    def transcribe(**)
      described_class.transcribe(audio_path, model: 'openai/gpt-4o-mini-transcribe', api_key: 'openrouter-key', **)
    end

    it 'sends the prompt as a provider option of the serving provider, not as a top-level field', :aggregate_failures do
      transcribe(prompt: 'Біздің ұлттық мәдениетіміз.', temperature: 0, provider: { zdr: true, data_collection: 'deny' })

      body = sent.fetch(0)
      expect(body).not_to have_key('prompt')
      expect(body.dig('provider', 'options')).to eq('openai' => { 'prompt' => 'Біздің ұлттық мәдениетіміз.' })
      expect(body['provider']).to include('zdr' => true, 'data_collection' => 'deny')
    end

    it 'keeps temperature 0 and sends no language', :aggregate_failures do
      transcribe(prompt: 'Біздің ұлттық мәдениетіміз.', temperature: 0, language: nil)

      body = sent.fetch(0)
      expect(body).to include('model' => 'openai/gpt-4o-mini-transcribe', 'temperature' => 0)
      expect(body).not_to have_key('language')
    end

    it 'adds the prompt next to the provider options that are already set', :aggregate_failures do
      transcribe(prompt: 'Біздің ұлттық мәдениетіміз.', provider: { options: { openai: { response_format: 'json' }, groq: { prompt: 'x' } } })

      expect(sent.fetch(0).dig('provider', 'options')).to eq(
        'openai' => { 'response_format' => 'json', 'prompt' => 'Біздің ұлттық мәдениетіміз.' },
        'groq' => { 'prompt' => 'x' }
      )
    end

    it 'uses the vendor of the model as the provider slug' do
      described_class.transcribe(audio_path, model: 'mistralai/voxtral-mini-transcribe', api_key: 'openrouter-key', prompt: 'Біздің')

      expect(sent.fetch(0).dig('provider', 'options')).to eq('mistralai' => { 'prompt' => 'Біздің' })
    end

    it 'sends no provider options without a prompt', :aggregate_failures do
      transcribe(prompt: '  ', temperature: 0, provider: { zdr: true })

      body = sent.fetch(0)
      expect(body['provider']).to eq('zdr' => true)
      expect(body.to_json).not_to include('prompt')
    end

    it 'sends no provider object when there is nothing to put in it' do
      transcribe(temperature: 0)

      expect(sent.fetch(0)).not_to have_key('provider')
    end

    it 'cannot place a prompt for a model id without a vendor and leaves the request valid', :aggregate_failures do
      described_class.transcribe(audio_path, model: 'whisper-1', api_key: 'openrouter-key', prompt: 'Біздің')

      expect(sent.fetch(0)).not_to have_key('provider')
      expect(sent.fetch(0)).not_to have_key('prompt')
    end
  end

  it 'raises a RubyLLM unauthorized error for invalid OpenRouter keys' do
    stub_request(:post, 'https://openrouter.ai/api/v1/audio/transcriptions')
      .to_return(status: 401, body: { error: { message: 'Invalid key' } }.to_json)

    expect do
      described_class.transcribe(
        audio_path,
        model: 'openai/gpt-4o-mini-transcribe',
        api_key: 'bad-key'
      )
    end.to raise_error(RubyLLM::UnauthorizedError, /Invalid key/)
  end
end
