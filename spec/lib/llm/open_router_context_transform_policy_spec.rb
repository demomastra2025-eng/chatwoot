# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::OpenRouterContextTransformPolicy do
  before do
    allow(Llm::Models).to receive(:model_config).with('openai/test-model', account: nil).and_return(model_config)
  end

  let(:context_length) { 100 }
  let(:model_config) { { 'context_length' => context_length } }

  it 'skips compression when transform policy is disabled' do
    plan = described_class.call(
      messages: [{ role: 'user', content: 'x' * 500 }],
      model: 'openai/test-model',
      policy: 'disabled'
    )

    expect(plan).to have_attributes(status: 'disabled', plugin: nil, reason: 'policy_disabled')
  end

  context 'with overflow-only policy' do
    let(:context_length) { 100 }

    it 'adds the context-compression plugin when estimated input exceeds the soft limit' do
      plan = described_class.call(
        messages: [{ role: 'user', content: 'x' * 360 }],
        model: 'openai/test-model',
        policy: 'overflow_only'
      )

      expect(plan).to have_attributes(
        status: 'applied',
        plugin: { id: 'context-compression', mode: 'overflow_only' },
        estimated_tokens: 90,
        context_limit: 100,
        soft_context_limit: 85
      )
    end

    it 'disables OpenRouter default compression on small endpoints when no overflow is present' do
      plan = described_class.call(
        messages: [{ role: 'user', content: 'short prompt' }],
        model: 'openai/test-model',
        policy: 'overflow_only'
      )

      expect(plan).to have_attributes(
        status: 'disabled_default',
        plugin: { id: 'context-compression', enabled: false },
        reason: 'prevent_hidden_openrouter_default_for_small_context'
      )
    end
  end
end
