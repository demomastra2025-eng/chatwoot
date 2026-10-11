# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::OpenRouterDecisionClient do
  let(:endpoint) { 'https://openrouter.ai/api/alpha/decisions' }
  let(:model) { 'microsoft/microsoft-decision-1' }
  let(:criteria) { { 'solved' => 'Question answered', 'other' => 'Other outcome' } }
  let(:response_body) do
    { id: 'gen-dec-synthetic', model: "#{model}-20261009", provider: 'Azure',
      answers: { reason: { choice: 'solved', confidence: 0.9, probabilities: { solved: 0.95, other: 0.05 } } },
      usage: { input_tokens: 100, output_tokens: 1, cost: 0.0000042, untrusted: 'do not retain' } }
  end

  def choose(**overrides)
    described_class.choose(**{ state: { messages: ['Thank you, answered.'] }, criteria: criteria, instructions: 'Classify the outcome.',
                              model: model, api_key: 'synthetic-key', api_base: 'https://openrouter.ai/api/v1' }.merge(overrides))
  end

  it 'uses the actual Decisions contract and retains only bounded metadata without prose or raw input' do
    stub = stub_request(:post, endpoint).with(headers: { 'Authorization' => 'Bearer synthetic-key' }) do |request|
      body = JSON.parse(request.body)
      expect(body.keys).to match_array(%w[model state questions provider])
      expect(body['questions']).to eq('reason' => { 'type' => 'choice', 'instructions' => 'Classify the outcome.', 'criteria' => criteria })
      expect(body['provider']).to eq('zdr' => true, 'allow_fallbacks' => false)
      expect(body).not_to have_key('messages')
    end.to_return(status: 200, body: response_body.to_json)

    result = choose(provider: { zdr: true, allow_fallbacks: false })

    expect(stub).to have_been_requested.once
    expect(result).to have_attributes(choice: 'solved', confidence: 0.9, model: "#{model}-20261009", provider: 'Azure')
    expect(result.usage).to eq('input_tokens' => 100, 'output_tokens' => 1, 'cost' => 0.0000042)
    expect(result).not_to respond_to(:raw)
  end

  %w[https://openrouter.ai/api https://openrouter.ai/api/v1/models https://openrouter.ai/api/v1/chat/completions
     https://openrouter.ai/api/alpha/decisions].each do |base|
    it "normalizes #{base} without inserting v1 before alpha" do
      stub = stub_request(:post, endpoint).to_return(status: 200, body: response_body.to_json)
      expect(choose(api_base: base).choice).to eq('solved')
      expect(stub).to have_been_requested.once
    end
  end

  it 'preserves a configured HTTPS proxy path and never follows redirects with the key' do
    stub_request(:post, 'https://proxy.example/private/api/alpha/decisions').to_return(status: 302, headers: { 'Location' => endpoint })
    expect { choose(api_base: 'https://proxy.example/private/api/v1') }.to raise_error(described_class::Error, /HTTP 302/)
    expect(a_request(:post, endpoint)).not_to have_been_made
  end

  ['http://openrouter.ai/api/v1', 'https://key@example.org/api/v1', 'https://openrouter.ai/api/v1?key=secret',
   'https://openrouter.ai/unknown'].each do |base|
    it "rejects unsafe or unsupported configured endpoints: #{base}" do
      expect { choose(api_base: base) }.to raise_error(ArgumentError, /endpoint/)
    end
  end

  it 'rejects an unverified model before network access' do
    expect { choose(model: 'microsoft/microsoft-decision-1-fake') }.to raise_error(ArgumentError, /Unsupported decision model/)
  end

  it 'rejects duplicate-free malformed choices and oversized request data before transport' do
    expect { choose(criteria: { 'only' => 'One' }) }.to raise_error(ArgumentError, /choices/)
    expect { choose(criteria: criteria.merge('extra' => [])) }.to raise_error(ArgumentError, /choices/)
    expect { choose(state: { text: 'x' * described_class::MAX_REQUEST_BYTES }) }.to raise_error(ArgumentError, /too large/)
  end

  it 'does not leak provider bodies, keys or customer text in HTTP and JSON errors' do
    secret = 'synthetic-key customer-private-example'
    stub_request(:post, endpoint).to_return(status: 401, body: { error: { message: secret } }.to_json)
    expect { choose }.to raise_error(described_class::Error, 'OpenRouter decision request failed (HTTP 401).')
    stub_request(:post, endpoint).to_return(status: 200, body: "broken #{secret}")
    expect { choose }.to raise_error(described_class::Error, 'OpenRouter decision returned invalid JSON.')
  end

  it 'rejects unknown or malformed answers instead of silently classifying them as other' do
    [[], {}, { model: model, answers: { reason: { choice: 'invented' } } },
     { model: model, answers: { reason: { choice: 'solved', confidence: 'high' } } }].each do |body|
      stub_request(:post, endpoint).to_return(status: 200, body: body.to_json)
      expect { choose }.to raise_error(described_class::Error, /invalid/)
    end
  end

  it 'stops a response larger than the bound' do
    stub_request(:post, endpoint).to_return(status: 200, body: 'x' * (described_class::MAX_RESPONSE_BYTES + 1))
    expect { choose }.to raise_error(described_class::Error, /response too large/)
  end

  it 'does not retry a timeout or a rate limit inside the bounded classifier lease' do
    stub = stub_request(:post, endpoint).to_timeout
    expect { choose }.to raise_error(described_class::Error, 'OpenRouter decision transport unavailable.')
    expect(stub).to have_been_requested.once
    rate_limit = stub_request(:post, endpoint).to_return(status: 429, body: '{}')
    expect { choose }.to raise_error(described_class::Error, /HTTP 429/)
    expect(rate_limit).to have_been_requested.twice
  end
end
