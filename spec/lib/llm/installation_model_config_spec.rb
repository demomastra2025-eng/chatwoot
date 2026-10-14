# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::InstallationModelConfig do
  describe '.manages?' do
    it 'covers every platform-managed model slot and the short list' do
      Llm::Config::INSTALLATION_MANAGED_MODEL_CONFIGS.each_value do |config_name|
        expect(described_class.manages?(config_name)).to be true
      end
      expect(described_class.manages?('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST')).to be true
      expect(described_class.manages?('CAPTAIN_DEFAULT_MODEL')).to be true
      expect(described_class.manages?('CAPTAIN_CUSTOM_GUARDRAIL_MODEL')).to be true
      expect(described_class.manages?('CAPTAIN_OPENROUTER_API_KEY')).to be false
    end
  end

  describe '.normalize for a model slot' do
    it 'treats a blank value as valid so that the built-in default applies' do
      expect(described_class.normalize('CAPTAIN_AUDIO_TRANSCRIPTION_MODEL', '  ')).to have_attributes(value: '', error: nil)
    end

    it 'accepts a catalog model that fits the feature and canonicalizes it' do
      result = described_class.normalize('CAPTAIN_AUDIO_TRANSCRIPTION_MODEL', ' openai/gpt-4o-mini-transcribe ')

      expect(result).to be_valid
      expect(result.value).to eq('openai/gpt-4o-mini-transcribe')
    end

    it 'rejects a model that is unknown or does not fit the feature' do
      expect(described_class.normalize('CAPTAIN_AUDIO_TRANSCRIPTION_MODEL', 'openai/gpt-5.4')).not_to be_valid
      expect(described_class.normalize('CAPTAIN_IMAGE_RECOGNITION_MODEL', 'vendor/unknown')).not_to be_valid
    end

    it 'accepts supported structured-output models and rejects unrelated models for the outcome classifier' do
      expect(described_class.normalize('CAPTAIN_OUTCOME_CLASSIFIER_MODEL', 'openai/gpt-6-luna')).to be_valid
      expect(described_class.normalize('CAPTAIN_OUTCOME_CLASSIFIER_MODEL', 'whisper-1')).not_to be_valid
      expect(described_class.normalize('CAPTAIN_OUTCOME_CLASSIFIER_MODEL', 'vendor/unknown')).not_to be_valid
    end

    it 'allows the language decision model only in its installation slot' do
      model = 'openai/gpt-6-luna-decisions'
      expect(described_class.normalize('CAPTAIN_LANGUAGE_DETECTION_MODEL', model)).to have_attributes(value: model, error: nil)
      expect(described_class.normalize('CAPTAIN_LANGUAGE_DETECTION_MODEL', 'openai/gpt-6-luna')).not_to be_valid
      expect(described_class.normalize('CAPTAIN_DEFAULT_MODEL', model)).not_to be_valid
    end

    %w[microsoft/microsoft-decision-1 microsoft/microsoft-decision-1-20261009].each do |model|
      it "accepts the approved native Decision model #{model} only for the outcome classifier" do
        expect(described_class.normalize('CAPTAIN_OUTCOME_CLASSIFIER_MODEL', " #{model} "))
          .to have_attributes(value: model, error: nil)
        expect(described_class.normalize('CAPTAIN_CUSTOM_GUARDRAIL_MODEL', model)).not_to be_valid
        expect(described_class.normalize('CAPTAIN_MODERATION_MODEL', model)).not_to be_valid
        expect(described_class.normalize('CAPTAIN_DEFAULT_MODEL', model)).not_to be_valid
      end
    end
  end

  describe '.normalize for the custom guardrail model' do
    let(:config_name) { 'CAPTAIN_CUSTOM_GUARDRAIL_MODEL' }

    def stub_guardrail_catalog_model(supported_parameters:)
      model = 'vendor/custom-guardrail-chat'
      allow(Llm::Models).to receive(:model_config).and_call_original
      allow(Llm::Models).to receive(:model_config).with(model, account: nil).and_return(
        'id' => model, 'provider' => 'openrouter', 'type' => 'chat',
        'capabilities' => %w[text_input text_output], 'supported_parameters' => supported_parameters
      )
      allow(Llm::Models).to receive(:openrouter_catalog_enabled?).and_call_original
      allow(Llm::Models).to receive(:openrouter_catalog_enabled?).with(account: nil).and_return(true)
      allow(Llm::Config).to receive(:provider_available?).and_call_original
      allow(Llm::Config).to receive(:provider_available?).with('openrouter', account: nil).and_return(true)
      allow(Llm::OpenRouterEndpointCatalog).to receive(:endpoint_metadata).and_call_original
      allow(Llm::OpenRouterEndpointCatalog).to receive(:endpoint_metadata).with(model).and_return('endpoints' => [])
      model
    end

    it 'accepts absent and blank values and keeps the built-in Luna fallback valid' do
      expect(described_class.normalize(config_name, nil)).to have_attributes(value: '', error: nil)
      expect(described_class.normalize(config_name, '  ')).to have_attributes(value: '', error: nil)
      expect(described_class.normalize(config_name, Llm::Config::DEFAULT_MODEL)).to be_valid
    end

    it 'accepts a supported catalog chat model and removes surrounding whitespace' do
      result = described_class.normalize(config_name, ' openai/gpt-6-luna ')

      expect(result).to be_valid
      expect(result.value).to eq('openai/gpt-6-luna')
    end

    it 'accepts structured-output chat without requiring agent tools or a provider-moderation capability' do
      model = stub_guardrail_catalog_model(supported_parameters: ['response_format'])

      expect(described_class.normalize(config_name, model)).to have_attributes(value: model, error: nil)
    end

    it 'rejects a known chat model whose installed metadata does not support structured output' do
      model = stub_guardrail_catalog_model(supported_parameters: ['temperature'])
      diagnostics = Llm::OpenRouterCapabilityResolver.call(model_id: model, feature: 'custom_guardrail')

      expect(diagnostics.missing).to include('structured_output')
      result = described_class.normalize(config_name, model)
      expect(result).not_to be_valid
      expect(result.value).to be_nil
      expect(result.error).to include(model)
    end

    it 'rejects nonchat and unknown model identifiers' do
      expect(described_class.normalize(config_name, 'whisper-1')).not_to be_valid
      expect(described_class.normalize(config_name, 'vendor/unknown')).not_to be_valid
    end
  end

  describe '.normalize for the default model' do
    let(:config_name) { 'CAPTAIN_DEFAULT_MODEL' }

    it 'treats a blank value as valid so that the built-in default applies' do
      expect(described_class.normalize(config_name, ' ')).to have_attributes(value: '', error: nil)
    end

    it 'accepts a model that fits the agent, the editor and the copilot' do
      expect(described_class.normalize(config_name, ' openai/gpt-5.6-luna ')).to have_attributes(value: 'openai/gpt-5.6-luna', error: nil)
    end

    it 'rejects a model that does not fit those features and names it' do
      result = described_class.normalize(config_name, 'openai/gpt-4o-mini-transcribe')

      expect(result).not_to be_valid
      expect(result.error).to include('openai/gpt-4o-mini-transcribe', 'assistant')
    end

    it 'rejects a model that is not on the short list the platform curated' do
      upsert_installation_config('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST', '["openai/gpt-6-luna"]')

      expect(described_class.normalize(config_name, 'openai/gpt-5.6-luna')).not_to be_valid
      expect(described_class.normalize(config_name, 'openai/gpt-6-luna')).to be_valid
    end
  end

  describe '.normalize for the short list' do
    let(:config_name) { 'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST' }

    it 'stores a normalized JSON array without duplicates and blanks' do
      result = described_class.normalize(config_name, '["openai/gpt-6-luna", "openai/gpt-5.6-luna ", "openai/gpt-6-luna", " "]')

      expect(result.value).to eq('["openai/gpt-6-luna","openai/gpt-5.6-luna"]')
    end

    it 'accepts an array value and a blank value' do
      expect(described_class.normalize(config_name, ['openai/gpt-6-luna']).value).to eq('["openai/gpt-6-luna"]')
      expect(described_class.normalize(config_name, nil)).to have_attributes(value: '', error: nil)
      expect(described_class.normalize(config_name, '[]')).to have_attributes(value: '', error: nil)
    end

    it 'rejects anything that is not a JSON array of model ids' do
      ['{broken', '{"a": 1}', '"text"', '[1, 2]', '[["openai/gpt-6-luna"]]'].each do |value|
        expect(described_class.normalize(config_name, value)).not_to be_valid
      end
    end

    it 'rejects models that are not in the catalog and names them' do
      result = described_class.normalize(config_name, '["openai/gpt-6-luna", "vendor/unknown"]')

      expect(result).not_to be_valid
      expect(result.error).to include('vendor/unknown')
      expect(result.error).not_to include('openai/gpt-6-luna')
    end

    it 'rejects a list that is not short' do
      models = Array.new(described_class::ALLOWLIST_LIMIT + 1) { |index| "vendor/model-#{index}" }

      expect(described_class.normalize(config_name, models)).not_to be_valid
    end

    it 'requires the default AI agent model to be on the list' do
      upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', '[REDACTED]')
      default_model = Llm::Config.model_for(feature: 'assistant', fallback: nil)
      other_model = (%w[openai/gpt-6-luna openai/gpt-5.6-luna] - [default_model]).first

      result = described_class.normalize(config_name, JSON.generate([other_model]))

      expect(result).not_to be_valid
      expect(result.error).to include(default_model)
      expect(described_class.normalize(config_name, JSON.generate([default_model]))).to be_valid
    end
  end
end
