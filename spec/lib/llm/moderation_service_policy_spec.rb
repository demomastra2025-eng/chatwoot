# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::ModerationService do
  let(:model) { 'test/synthetic-moderator' }
  let(:retired_models) do
    %w[openai/gpt-oss-20b openai/gpt-oss-safeguard-20b openai/gpt-oss-120b:free openai.gpt-oss-20b-1:0 openai.gpt-oss-safeguard-20b]
  end
  let(:chat) { instance_double(RubyLLM::Chat) }
  let(:features) { %i[assistant editor moderation council_split] }
  let(:capabilities) { %w[text_input text_output structured_output moderation tool_calling tool_choice streaming] }

  before do
    upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', 'synthetic-key')
    catalog = ([model] + retired_models).index_with do
      { 'provider' => 'openrouter', 'type' => 'chat', 'capabilities' => capabilities }
    end
    allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(catalog)
    allow(Llm::RuntimePolicy).to receive(:no_thinking_options).and_return(nil)
  end

  it 'runs the configured non-retired validator when the workspace explicitly enables moderation' do
    upsert_installation_config('CAPTAIN_MODERATION_MODEL', model)
    response = instance_double(RubyLLM::Message, content: { 'flagged' => false, 'categories' => [], 'reason' => 'safe' })
    expect(Llm::Runtime).to receive(:build_chat).with(feature: :moderation, account: nil, model: model,
                                                      options: { temperature: 0 }).and_return(chat)
    expect(Llm::StructuredOutputPolicy).to receive(:bind!).with(chat: chat, schema: kind_of(Hash)).and_return(chat)
    expect(Llm::Runtime).to receive(:ask).and_return(response)

    result = Llm::SafetyPolicy.check!(feature: :editor, stage: :input, content: 'Synthetic text',
                                      preferences: { 'editor_moderation' => true })

    expect(result.moderation).to have_attributes(status: :allowed, model: model)
  end

  [nil, false].each do |enabled|
    it "makes no provider call when workspace moderation is #{enabled.inspect}" do
      upsert_installation_config('CAPTAIN_MODERATION_MODEL', model)
      expect(Llm::Runtime).not_to receive(:build_chat)
      expect(Llm::Runtime).not_to receive(:ask)

      result = Llm::SafetyPolicy.check!(feature: :editor, stage: :input, content: 'Synthetic text',
                                        preferences: { 'editor_moderation' => enabled }.compact)

      expect(result.moderation.status).to eq(:disabled)
    end
  end

  it 'keeps retired models in the catalog but excludes them from active features and saved curated lists' do
    upsert_installation_config('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST', ([model] + retired_models).to_json)
    expect(Llm::Models.models.keys).to include(*retired_models)

    retired_models.each do |retired|
      expect(Llm::Models.runtime_supported?(retired)).to be(false)
      features.each do |feature|
        expect(Llm::Models.model_allowed_for_feature?(feature, retired)).to be(false)
        expect(Llm::Models.models_for(feature)).not_to include(retired)
        expect(Llm::OpenRouterModelMigration.resolve(retired, feature: feature)).to be_nil
      end
    end
    expect(Llm::Models.curated_model_names_for(:editor)).to eq([model])
    expect(Llm::Models.retired_model?('vendor/another-oss-model')).to be(false)
  end

  %w[omni-moderation-latest openai/gpt-oss-safeguard-20b openai/gpt-oss-20b].each do |retired|
    it "fails closed with the real configuration resolver for #{retired}" do
      upsert_installation_config('CAPTAIN_MODERATION_MODEL', retired)
      expect(Llm::Runtime).not_to receive(:build_chat)
      expect(Llm::Runtime).not_to receive(:ask)

      expect do
        Llm::SafetyPolicy.check!(feature: :editor, stage: :input, content: 'Synthetic text',
                                 preferences: { 'editor_moderation' => true, 'moderation_failure_mode' => 'fail_open' })
      end.to raise_error(Llm::SafetyPolicy::UnavailableError)
    end
  end
end
