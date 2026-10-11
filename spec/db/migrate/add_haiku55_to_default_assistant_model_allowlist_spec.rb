# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20261011100000_add_haiku55_to_default_assistant_model_allowlist')

RSpec.describe AddHaiku55ToDefaultAssistantModelAllowlist do
  let(:config_name) { 'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST' }
  let(:previous_models) { %w[openai/gpt-6-luna openai/gpt-5.6-luna openai/gpt-5.4 openai/gpt-5.4-mini] }
  let(:added_model) { 'anthropic/claude-haiku-5.5' }
  let(:migration) { described_class.new }

  it 'does not create a persisted restriction when the configuration is absent' do
    InstallationConfig.where(name: config_name).delete_all

    expect { migration.up }.not_to(change { InstallationConfig.count })
    expect(InstallationConfig.find_by(name: config_name)).to be_nil
  end

  [nil, '', '  ', '[]', []].each do |value|
    it "preserves an explicitly empty setting #{value.inspect}" do
      config = upsert_installation_config(config_name, value)

      expect { migration.up }.not_to(change { config.reload.updated_at })
      expect(config.reload.value).to eq(value)
    end
  end

  it 'appends Haiku to the exact prior standard JSON list without changing feature defaults' do
    config = upsert_installation_config(config_name, JSON.generate(previous_models))
    default_config = upsert_installation_config('CAPTAIN_DEFAULT_MODEL', 'openai/gpt-6-luna')
    classifier_config = upsert_installation_config('CAPTAIN_OUTCOME_CLASSIFIER_MODEL', 'microsoft/microsoft-decision-1')
    guardrail_config = upsert_installation_config('CAPTAIN_CUSTOM_GUARDRAIL_MODEL', 'openai/gpt-6-luna')

    migration.up

    expect(JSON.parse(config.reload.value)).to eq(previous_models + [added_model])
    expect(default_config.reload.value).to eq('openai/gpt-6-luna')
    expect(classifier_config.reload.value).to eq('microsoft/microsoft-decision-1')
    expect(guardrail_config.reload.value).to eq('openai/gpt-6-luna')
  end

  it 'preserves the native array representation of a prior standard list' do
    config = upsert_installation_config(config_name, previous_models)

    migration.up

    expect(config.reload.value).to eq(previous_models + [added_model])
  end

  it 'does not duplicate Haiku or write the setting again when replayed' do
    config = upsert_installation_config(config_name, JSON.generate(previous_models))
    migration.up
    first_value = config.reload.value

    expect { migration.up }.not_to(change { config.reload.updated_at })
    expect(config.reload.value).to eq(first_value)
    expect(JSON.parse(first_value).count(added_model)).to eq(1)
  end

  it 'preserves customized lists including intentionally changed ordering or an extra model' do
    [previous_models.reverse, previous_models.first(2), previous_models + ['vendor/custom-chat']].each do |models|
      config = upsert_installation_config(config_name, JSON.generate(models))

      expect { migration.up }.not_to(change { config.reload.updated_at })
      expect(config.reload.value).to eq(JSON.generate(models))
    end
  end

  it 'does not reapply the addition after an administrator has removed it and narrowed the list' do
    config = upsert_installation_config(config_name, JSON.generate(previous_models))
    migration.up
    config.update!(value: JSON.generate(previous_models.first(2)))

    migration.up

    expect(config.reload.value).to eq(JSON.generate(previous_models.first(2)))
  end

  it 'preserves malformed or nonarray settings instead of replacing an administrator value' do
    ['{broken', '"custom"', '{"model":"openai/gpt-6-luna"}'].each do |value|
      config = upsert_installation_config(config_name, value)

      expect { migration.up }.not_to(change { config.reload.updated_at })
      expect(config.reload.value).to eq(value)
    end
  end
end
