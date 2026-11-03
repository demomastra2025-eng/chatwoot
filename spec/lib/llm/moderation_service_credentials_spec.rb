# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::ModerationService do
  let(:model) { 'test/installed-moderator' }
  let(:cache_store) { ActiveSupport::Cache::MemoryStore.new }
  let(:capabilities) { %w[text_input text_output structured_output moderation] }
  let!(:entry) do
    Llm::ModelCatalogEntry.create!(
      provider_platform: 'openrouter', model_id: model, display_name: 'Synthetic moderator', model_type: 'chat',
      capabilities: capabilities, input_modalities: ['text'], output_modalities: ['text'],
      supported_parameters: ['response_format'], fetched_at: Time.current
    )
  end

  before do
    allow(Rails).to receive(:cache).and_return(cache_store)
    reset_catalog_snapshot
    upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', nil)
    upsert_installation_config('CAPTAIN_MODERATION_MODEL', model)
  end

  after { reset_catalog_snapshot }

  def reset_catalog_snapshot
    %i[@last_model_configs @cached_model_configs @cached_model_configs_refresh_marker @cached_model_configs_loaded].each do |name|
      Llm::OpenRouterModelCatalog.instance_variable_set(name, nil)
    end
    Rails.cache.delete(Llm::OpenRouterModelCatalog::CACHE_KEY)
    Rails.cache.delete(Llm::OpenRouterModelCatalog::DB_CONFIG_CACHE_KEY)
  end

  it 'retains valid installed model metadata without a key and preserves the explicit fail-open mode' do
    expect(Llm::Config.moderation_model).to eq(model)
    expect(Llm::Runtime).not_to receive(:build_chat)
    expect(Llm::Runtime).not_to receive(:ask)

    result = described_class.check!(feature: :editor, stage: :input, content: 'Synthetic text',
                                    preferences: { 'editor_moderation' => true, 'moderation_failure_mode' => 'fail_open' })

    expect(result).to have_attributes(status: :skipped, reason: :provider_not_configured, model: model)
  end

  it 'preserves fail-closed credentials handling with the real configured model resolver' do
    expect(Llm::Config.moderation_model).to eq(model)
    expect(Llm::Runtime).not_to receive(:build_chat)

    expect do
      described_class.check!(feature: :editor, stage: :input, content: 'Synthetic text',
                             preferences: { 'editor_moderation' => true, 'moderation_failure_mode' => 'fail_closed' })
    end.to raise_error(described_class::UnavailableError) { |error| expect(error.reason).to eq(:provider_not_configured) }
  end

  it 'does not forgive missing capabilities just because the credentials are absent' do
    entry.update!(capabilities: %w[text_input text_output])
    expect(Llm::Config.moderation_model).to be_nil
    expect(Llm::Runtime).not_to receive(:build_chat)

    expect do
      described_class.check!(feature: :editor, stage: :input, content: 'Synthetic text',
                             preferences: { 'editor_moderation' => true, 'moderation_failure_mode' => 'fail_open' })
    end.to raise_error(described_class::UnavailableError) { |error| expect(error.reason).to eq(:model_not_configured) }
  end

  it 'does not forgive unknown metadata just because the credentials are absent' do
    upsert_installation_config('CAPTAIN_MODERATION_MODEL', 'test/unknown-moderator')
    expect(Llm::Config.moderation_model).to be_nil
    expect(Llm::Runtime).not_to receive(:build_chat)

    expect do
      described_class.check!(feature: :editor, stage: :input, content: 'Synthetic text',
                             preferences: { 'editor_moderation' => true, 'moderation_failure_mode' => 'fail_open' })
    end.to raise_error(described_class::UnavailableError) { |error| expect(error.reason).to eq(:model_not_configured) }
  end
end
