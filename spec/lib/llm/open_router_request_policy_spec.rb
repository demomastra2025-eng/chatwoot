# frozen_string_literal: true

require 'rails_helper'

OpenRouterRequestPolicySpecModel = Struct.new(:id, :provider)

class OpenRouterRequestPolicySpecChat
  attr_reader :model, :params, :with_params_calls

  def initialize(model:, params: {})
    @model = model
    @params = params
    @with_params_calls = []
  end

  def with_params(**params)
    @params = params
    @with_params_calls << params
    self
  end
end

RSpec.describe Llm::OpenRouterRequestPolicy do
  describe '.require_parameters!' do
    it 'adds provider require_parameters for OpenRouter chats and preserves existing params' do
      chat = OpenRouterRequestPolicySpecChat.new(
        model: OpenRouterRequestPolicySpecModel.new('deepseek/deepseek-v4-pro', 'openrouter'),
        params: {
          'logit_bias' => { '123' => -1 },
          'provider' => { 'allow_fallbacks' => true },
          :max_tokens => 200
        }
      )

      result = described_class.require_parameters!(chat)

      expect(result).to eq(chat)
      expect(chat.params).to include(
        'logit_bias' => { '123' => -1 },
        :max_tokens => 200,
        :provider => include(:allow_fallbacks => true, :require_parameters => true)
      )
    end

    it 'adds provider require_parameters for registry-resolved OpenRouter model ids' do
      chat = OpenRouterRequestPolicySpecChat.new(model: 'openai/gpt-5.4')

      allow(Llm::Models).to receive(:provider_for).with('openai/gpt-5.4', account: nil).and_return('openrouter')

      described_class.require_parameters!(chat)

      expect(chat.params).to include(provider: include(require_parameters: true))
    end

    it 'uses tagged account and feature metadata for existing chat instances' do
      account = create(:account)
      chat = OpenRouterRequestPolicySpecChat.new(model: 'custom/model')
      described_class.tag!(chat, account: account, feature: :copilot, model: 'custom/model')

      allow(Llm::Models).to receive(:provider_for).with('custom/model', account: account).and_return('openrouter')

      described_class.require_parameters!(chat)

      expect(chat.params).to include(
        provider: include(
          require_parameters: true,
          sort: { by: 'latency', partition: 'none' }
        )
      )
    end

    it 'does not mutate non-OpenRouter chats' do
      chat = OpenRouterRequestPolicySpecChat.new(
        model: OpenRouterRequestPolicySpecModel.new('gpt-4.1-mini', 'openai'),
        params: { temperature: 0.2 }
      )

      described_class.require_parameters!(chat)

      expect(chat.params).to eq(temperature: 0.2)
      expect(chat.with_params_calls).to be_empty
    end
  end

  describe '.require_structured_output!' do
    it 'adds response healing and provider require_parameters for OpenRouter structured output calls' do
      chat = OpenRouterRequestPolicySpecChat.new(
        model: OpenRouterRequestPolicySpecModel.new('deepseek/deepseek-v4-pro', 'openrouter'),
        params: {
          plugins: [{ id: 'web' }],
          provider: { sort: 'latency' }
        }
      )

      described_class.require_structured_output!(chat)

      expect(chat.params).to include(
        provider: include(sort: 'latency', require_parameters: true),
        plugins: include({ id: 'web' }, { id: 'response-healing' })
      )
    end

    it 'does not duplicate the response healing plugin' do
      chat = OpenRouterRequestPolicySpecChat.new(
        model: OpenRouterRequestPolicySpecModel.new('deepseek/deepseek-v4-pro', 'openrouter'),
        params: { plugins: [{ 'id' => 'response-healing' }] }
      )

      described_class.require_structured_output!(chat)

      expect(chat.params[:plugins].count { |plugin| plugin[:id] == 'response-healing' || plugin['id'] == 'response-healing' }).to eq(1)
    end
  end
end
