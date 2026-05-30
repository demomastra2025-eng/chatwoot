# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::FeatureRequest do
  let(:account) { instance_double(Account, id: 42) }
  let(:tool) { instance_double(RubyLLM::Tool, name: 'lookup_contact') }
  let(:schema) do
    Class.new(RubyLLM::Schema) do
      string :message
    end
  end

  it 'normalizes feature aliases and exposes request helpers' do
    request = described_class.new(
      feature: :assistant,
      account: account,
      model: 'openai/gpt-5.4-mini',
      messages: [{ role: 'user', content: 'Hello' }],
      schema: schema,
      tools: [tool],
      attachments: ['https://example.com/image.png'],
      runtime_preferences: { privacy_profile: 'sensitive' },
      observability: { trace_id: 'trace-1' },
      options: { stream: false }
    )

    expect(request.feature_key).to eq('captain_agent')
    expect(request.account_id).to eq(42)
    expect(request.requires_tools?).to be(true)
    expect(request.requires_schema?).to be(true)
    expect(request.multimodal?).to be(true)
    expect(request.image?).to be(true)
    expect(request.audio?).to be(false)
    expect(request.privacy_profile).to eq('standard')
    expect(request.runtime_preferences).to eq(privacy_profile: 'sensitive')
    expect(request.observability).to eq(trace_id: 'trace-1')
    expect(request.options).to eq(stream: false)
  end

  it 'treats audio transcription requests as audio and multimodal' do
    request = described_class.new(
      feature: :audio_transcription,
      account: account,
      input: '/tmp/message.ogg'
    )

    expect(request.feature_key).to eq('audio_transcription')
    expect(request.audio?).to be(true)
    expect(request.image?).to be(false)
    expect(request.multimodal?).to be(true)
  end

  it 'maps help center search to the embedding runtime feature' do
    request = described_class.new(feature: :help_center_search, account: account, input: 'knowledge')

    expect(request.feature_key).to eq('embedding')
  end

  it 'rejects blank and unsupported features' do
    expect { described_class.new(feature: nil, account: account) }
      .to raise_error(ArgumentError, /feature is required/)

    expect { described_class.new(feature: :unknown_feature, account: account) }
      .to raise_error(ArgumentError, /Unsupported LLM feature/)
  end

  it 'rejects account-scoped requests without an account' do
    expect { described_class.new(feature: :captain_agent, messages: []) }
      .to raise_error(ArgumentError, /account is required/)
  end

  it 'rejects schemas and tools that are not runtime-compatible' do
    expect do
      described_class.new(feature: :captain_agent, account: account, schema: Object.new)
    end.to raise_error(ArgumentError, /schema must be RubyLLM-compatible/)

    expect do
      described_class.new(feature: :captain_agent, account: account, tools: ['lookup_contact'])
    end.to raise_error(ArgumentError, /tools must be RubyLLM-compatible/)
  end
end
