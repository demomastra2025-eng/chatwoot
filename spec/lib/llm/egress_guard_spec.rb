require 'rails_helper'

RSpec.describe Llm::EgressGuard do
  def sdk_connection
    context = RubyLLM.context do |config|
      config.openrouter_api_key = 'synthetic-key'
      config.openrouter_api_base = 'https://openrouter.example/api/v1'
      config.max_retries = 2
      config.retry_interval = 0
      config.retry_interval_randomness = 0
    end
    RubyLLM::Connection.new(RubyLLM::Providers::OpenRouter.new(context.config), context.config)
  end

  it 'does nothing outside an explicit scope' do
    expect { described_class.check! }.not_to raise_error
  end

  it 'restores nested validators after success and after a control-flow abort' do
    calls = []
    described_class.with(validation: -> { calls << :outer }) do
      described_class.with(validation: -> { calls << :inner }) { described_class.check! }
      expect do
        described_class.with(validation: -> { raise 'PRIVATE_VALIDATION_DETAIL' }) { described_class.check! }
      end.to raise_error(described_class::Blocked) { |error| expect(error.cause).to be_nil }
      described_class.check!
    end
    described_class.check!
    expect(calls).to eq([:inner, :outer])
  end

  it 'does not leak a validator into another thread or a later unscoped request' do
    checks = 0
    described_class.with(validation: -> { checks += 1 }) do
      Thread.new { described_class.check! }.value
      described_class.check!
    end
    described_class.check!
    expect(checks).to eq(1)
  end

  it 'preserves the normal SDK HTTP retry without an opt-in scope' do
    wire = stub_request(:post, 'https://openrouter.example/api/v1/chat/completions')
           .to_return(status: 503, body: '{"error":{"message":"synthetic unavailable"}}', headers: { 'Content-Type' => 'application/json' })
           .then.to_return(status: 200, body: '{}', headers: { 'Content-Type' => 'application/json' })

    response = sdk_connection.post('chat/completions', { model: 'synthetic', messages: [{ role: 'user', content: 'synthetic' }] })

    expect(response.status).to eq(200)
    expect(wire).to have_been_requested.twice
  end

  it 'raises an opaque non-retryable abort with no retained validation cause' do
    error = nil
    begin
      described_class.with(validation: -> { raise 'PRIVATE_DB_DETAIL' }) { described_class.check! }
    rescue described_class::Blocked => e
      error = e
    end
    expect(error).not_to be_a(StandardError)
    expect(error.message).to eq('LLM egress permission revoked')
    expect(error.cause).to be_nil
    expect { described_class.check! }.not_to raise_error
  end
end
