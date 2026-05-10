# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Config do
  before do
    described_class.reset!
  end

  describe 'defaults' do
    it 'uses an OpenRouter-routed GPT model as the global fallback model' do
      expect(described_class::DEFAULT_MODEL).to eq('openai/gpt-5.4-mini')
    end
  end

  describe '.provider_for_model' do
    it 'resolves provider through the product model registry' do
      expect(described_class.provider_for_model('gemini-2.5-pro')).to eq('gemini')
    end

    it 'returns nil for a blank model instead of inventing an OpenAI provider' do
      expect(described_class.provider_for_model(nil)).to be_nil
      expect(described_class.provider_for_model('')).to be_nil
    end

    it 'infers OpenRouter for provider-prefixed model ids discovered from OpenRouter' do
      upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', '[REDACTED]')
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/gpt-4o' => { 'provider' => 'openrouter', 'type' => 'chat', 'capabilities' => %w[streaming] }
      )

      expect(described_class.provider_for_model('openai/gpt-4o')).to eq('openrouter')
    end
  end

  describe '.api_key' do
    it 'reads provider-specific installation config' do
      upsert_installation_config('CAPTAIN_ANTHROPIC_API_KEY', 'anthropic-key')

      expect(described_class.api_key('anthropic')).to eq('anthropic-key')
    end

    it 'reads the OpenRouter installation config' do
      upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', '[REDACTED]')

      expect(described_class.api_key('openrouter')).to eq('[REDACTED]')
    end

    it 'prefers account integration hook credentials over installation credentials' do
      account = create(:account)
      create(
        :integrations_hook,
        account: account,
        app_id: 'openrouter',
        access_token: 'account-openrouter-key',
        settings: { 'api_base' => 'https://account-openrouter.example/api/v1' }
      )
      upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', 'global-openrouter-key')
      upsert_installation_config('CAPTAIN_OPENROUTER_ENDPOINT', 'https://global-openrouter.example/api/v1')

      expect(described_class.api_key('openrouter', account: account)).to eq('account-openrouter-key')
      expect(described_class.api_base('openrouter', account: account)).to eq('https://account-openrouter.example/api/v1')
    end

    it 'uses account hook settings api_key when access_token is blank' do
      account = create(:account)
      hook = create(
        :integrations_hook,
        account: account,
        app_id: 'openrouter',
        settings: { api_key: 'settings-openrouter-key' }
      )
      hook.update!(access_token: nil)
      upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', 'global-openrouter-key')

      expect(described_class.api_key('openrouter', account: account)).to eq('settings-openrouter-key')
    end

    it 'prefers account hook access_token over settings api_key' do
      account = create(:account)
      create(
        :integrations_hook,
        account: account,
        app_id: 'openrouter',
        access_token: 'access-token-openrouter-key',
        settings: { api_key: 'settings-openrouter-key' }
      )

      expect(described_class.api_key('openrouter', account: account)).to eq('access-token-openrouter-key')
    end
  end

  describe '.api_base' do
    it 'uses the default OpenRouter API base when no custom endpoint is configured' do
      expect(described_class.api_base('openrouter')).to eq('https://openrouter.ai/api/v1')
    end

    it 'keeps custom OpenRouter API base unchanged except for trailing slash' do
      upsert_installation_config('CAPTAIN_OPENROUTER_ENDPOINT', 'https://openrouter.example/api/v1/')

      expect(described_class.api_base('openrouter')).to eq('https://openrouter.example/api/v1')
    end
  end

  describe '.installation_default_model' do
    it 'prefers the provider-neutral default model setting' do
      upsert_installation_config('CAPTAIN_DEFAULT_MODEL', 'claude-sonnet-4-6')
      upsert_installation_config('CAPTAIN_OPEN_AI_MODEL', 'gpt-4.1-mini')

      expect(described_class.installation_default_model).to eq('claude-sonnet-4-6')
    end

    it 'falls back to the legacy OpenAI model setting when needed' do
      upsert_installation_config('CAPTAIN_OPEN_AI_MODEL', 'gpt-4.1-mini')

      expect(described_class.installation_default_model).to eq('gpt-4.1-mini')
    end
  end

  describe '.context' do
    it 'configures the selected provider in an isolated RubyLLM context' do
      yielded_config = Class.new do
        attr_accessor :gemini_api_key, :gemini_api_base
      end.new
      allow(yielded_config).to receive(:gemini_api_key=)
      allow(yielded_config).to receive(:gemini_api_base=)

      expect(RubyLLM).to receive(:context).and_yield(yielded_config)
      expect(yielded_config).to receive(:gemini_api_key=).with('gemini-key')
      expect(yielded_config).to receive(:gemini_api_base=).with('https://example.com')

      described_class.context(
        provider: 'gemini',
        api_key: 'gemini-key',
        api_base: 'https://example.com'
      )
    end

    it 'does not route explicit api_key/api_base overrides to OpenAI without provider/model' do
      expect(RubyLLM).not_to receive(:context)

      expect(described_class.context(api_key: 'legacy-key', api_base: 'https://legacy.example')).to be_nil
    end
  end

  describe '.model_for' do
    it 'normalizes legacy Anthropic aliases from installation config when the provider key is configured' do
      upsert_installation_config('CAPTAIN_DEFAULT_MODEL', 'claude-sonnet-4.6')
      upsert_installation_config('CAPTAIN_ANTHROPIC_API_KEY', 'anthropic-key')

      expect(described_class.model_for(feature: 'assistant')).to eq('claude-sonnet-4-6')
    end

    it 'uses a capability-compatible OpenRouter equivalent for chat feature defaults when OpenRouter is configured' do
      upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', '[REDACTED]')
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/gpt-5.4' => {
          'provider' => 'openrouter',
          'type' => 'chat',
          'capabilities' => %w[structured_output tool_calling image_input streaming]
        }
      )

      expect(described_class.model_for(feature: 'assistant')).to eq('openai/gpt-5.4')
    end

    it 'prefers the direct provider default when that provider key is configured alongside OpenRouter' do
      upsert_installation_config('CAPTAIN_OPEN_AI_API_KEY', 'openai-key')
      upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', '[REDACTED]')
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/gpt-5.4' => {
          'provider' => 'openrouter',
          'type' => 'chat',
          'capabilities' => %w[structured_output tool_calling image_input streaming]
        }
      )

      expect(described_class.model_for(feature: 'assistant')).to eq('gpt-5.4')
    end

    it 'prefers an account-selected model when that account has provider credentials' do
      account = create(:account)
      create(:integrations_hook, account: account, app_id: 'openrouter', access_token: 'account-openrouter-key', settings: {})
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/gpt-4o' => {
          'provider' => 'openrouter',
          'type' => 'chat',
          'capabilities' => %w[structured_output tool_calling image_input streaming]
        }
      )
      account.update!(captain_models: { 'assistant' => 'openai/gpt-4o' })

      expect(described_class.model_for(feature: 'assistant', account: account)).to eq('openai/gpt-4o')
      expect(described_class.provider_for_model('openai/gpt-4o', account: account)).to eq('openrouter')
    end

    it 'allows an account-selected OpenRouter model to use the global OpenRouter key' do
      account = create(:account)
      upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', '[REDACTED]')
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/gpt-4o' => {
          'provider' => 'openrouter',
          'type' => 'chat',
          'capabilities' => %w[structured_output tool_calling image_input streaming]
        }
      )
      account.update!(captain_models: { 'assistant' => 'openai/gpt-4o' })

      expect(described_class.model_for(feature: 'assistant', account: account)).to eq('openai/gpt-4o')
      expect(described_class.account_provider_available?('openrouter', account: account)).to be false
      expect(described_class.provider_available?('openrouter', account: account)).to be true
    end

    it 'uses a preferred OpenRouter audio chat model for audio transcription when OpenRouter is configured' do
      upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', '[REDACTED]')
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/gpt-audio-mini' => {
          'provider' => 'openrouter',
          'type' => 'chat',
          'capabilities' => %w[audio_input text_output structured_output streaming]
        }
      )

      expect(described_class.model_for(feature: 'audio_transcription')).to eq('openai/gpt-audio-mini')
      expect(described_class.provider_for_model(described_class.model_for(feature: 'audio_transcription'))).to eq('openrouter')
    end

    it 'keeps help center search on explicit embedding configuration instead of inventing an OpenRouter embedding model' do
      upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', '[REDACTED]')
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/text-embedding-3-small' => {
          'provider' => 'openrouter',
          'type' => 'chat',
          'capabilities' => %w[structured_output tool_calling streaming]
        }
      )

      expect(described_class.model_for(feature: 'help_center_search')).to be_nil
    end
  end

  describe '.moderation_model' do
    it 'defaults moderation to an OpenRouter guard model when OpenRouter is primary' do
      upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', '[REDACTED]')
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/gpt-oss-safeguard-20b' => {
          'provider' => 'openrouter',
          'type' => 'chat',
          'capabilities' => %w[text_input text_output structured_output streaming]
        }
      )

      expect(described_class.moderation_model).to eq('openai/gpt-oss-safeguard-20b')
      expect(described_class.moderation_provider).to eq('openrouter')
    end

    it 'overrides an OpenAI moderation config with an OpenRouter guard when OpenRouter is primary' do
      upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', '[REDACTED]')
      upsert_installation_config('CAPTAIN_MODERATION_MODEL', 'omni-moderation-latest')
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/gpt-oss-safeguard-20b' => {
          'provider' => 'openrouter',
          'type' => 'chat',
          'capabilities' => %w[text_input text_output structured_output streaming]
        }
      )

      expect(described_class.moderation_model).to eq('openai/gpt-oss-safeguard-20b')
      expect(described_class.moderation_provider).to eq('openrouter')
    end
  end
end
