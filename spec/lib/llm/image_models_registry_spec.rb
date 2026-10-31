# frozen_string_literal: true

require 'rails_helper'

# The models that read a customer's image. A model that is new to OpenRouter reaches the synced catalog only at its next refresh, and the
# product refused an image for a model it did not know (Llm::CapabilityPolicy: "does not support image inputs"). GPT-6.1 Terra is the
# reader of handwriting (benchmark 27.10), so it must take images from the day it exists.
RSpec.describe 'The registry of the image models' do # rubocop:disable RSpec/DescribeClass
  let(:image_content) do
    png = Vips::Image.black(8, 8, bands: 3).write_to_buffer('.png')
    RubyLLM::Content.new('Read it').add_attachment(StringIO.new(png), filename: 'image.png')
  end
  # The entry of the OpenRouter models list for Terra, as the catalog sync normalizes it.
  let(:terra_listing) do
    {
      'id' => 'openai/gpt-6.1-terra', 'name' => 'OpenAI: GPT-6.1 Terra', 'context_length' => 1_050_000,
      'architecture' => { 'input_modalities' => %w[file image text], 'output_modalities' => %w[text] },
      'top_provider' => { 'max_completion_tokens' => 128_000 },
      'supported_parameters' => %w[include_reasoning max_tokens reasoning reasoning_effort response_format seed structured_outputs
                                   tool_choice tools verbosity]
    }
  end

  before do
    allow(Llm::Config).to receive(:provider_available?) { |provider, **| provider == 'openrouter' }
  end

  %w[openai/gpt-6.1-terra google/gemini-3.1-flash-lite].each do |model|
    context "with #{model} while the synced catalog does not have it yet" do
      before { allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return({}) }

      it 'takes image input' do
        expect(Llm::Models.supports_image_input?(model)).to be(true)
        expect(Llm::Models.supports_multimodal_input?(model)).to be(true)
        expect { Llm::CapabilityPolicy.ensure_input_supported!(model: model, content: image_content) }.not_to raise_error
      end

      it 'is a model of the image reading, resolved to OpenRouter' do
        expect(Llm::Models.model_allowed_for_feature?('image_recognition', model)).to be(true)
        expect(Llm::Models.provider_for(model)).to eq('openrouter')
        expect(Llm::Models.runtime_supported?(model)).to be(true)
      end
    end
  end

  context 'with Terra once the synced catalog has it' do
    before do
      entry = Llm::OpenRouterModelCatalog.send(:normalize_chat_model, terra_listing, source: 'openrouter_api')
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(entry.first => entry.last)
    end

    it 'takes image input from the catalog entry' do
      expect(Llm::Models.supports_image_input?('openai/gpt-6.1-terra')).to be(true)
      expect { Llm::CapabilityPolicy.ensure_input_supported!(model: 'openai/gpt-6.1-terra', content: image_content) }.not_to raise_error
    end
  end

  it 'still refuses an image for a text-only model' do
    text_only = { 'provider' => 'openrouter', 'type' => 'chat', 'capabilities' => %w[text_input text_output streaming] }
    allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return('vendor/text-only' => text_only)

    expect { Llm::CapabilityPolicy.ensure_input_supported!(model: 'vendor/text-only', content: image_content) }
      .to raise_error(Llm::CapabilityPolicy::UnsupportedCapabilityError, /image inputs/)
  end

  describe 'the handwriting reader' do
    before { allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return({}) }

    it 'is offered Terra, the other OpenAI readers of the platform, and nothing the image slots cannot hold' do
      expect(Llm::Models.model_allowed_for_feature?('image_handwriting', 'openai/gpt-6.1-terra')).to be(true)
      expect(Llm::Models.model_allowed_for_feature?('image_handwriting', 'openai/gpt-6-luna')).to be(true)
      expect(Llm::Models.model_allowed_for_feature?('image_handwriting', 'perplexity/pplx-decider-v1.2')).to be(false)
    end
  end

  describe 'the router' do
    before { allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return({}) }

    it 'is a decision feature that takes the trusted ZDR decision models only' do
      expect(Llm::FeatureProfile.decision_feature?(:image_routing)).to be(true)
      %w[perplexity/pplx-decider-v1.2 perplexity/pplx-decider-flash-v1.2].each do |model|
        expect(Llm::Models.model_allowed_for_feature?('image_routing', model)).to be(true)
        expect(Llm::OpenRouterDecisionClient.supported_model?(model)).to be(true)
        expect(Llm::OpenRouterRoutingProfile.trusted_image_providers(model)).to be_present
      end
      expect(Llm::Models.model_allowed_for_feature?('image_routing', 'openai/gpt-6-luna-decisions')).to be(false)
      expect(Llm::Models.model_allowed_for_feature?('image_routing', 'openai/gpt-6.1-terra')).to be(false)
    end

    it 'has a trusted provider for every model the three image features list' do
      %w[image_recognition image_handwriting image_routing].each do |feature|
        listed = Array(Llm::Models.features.dig(feature, 'models')).select { |model| model.include?('/') }

        expect(listed).not_to be_empty
        listed.each do |model|
          expect(Llm::OpenRouterRoutingProfile.trusted_image_providers(model)).to be_present, "#{feature}: #{model} has no trusted provider"
        end
      end
    end
  end
end
