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
