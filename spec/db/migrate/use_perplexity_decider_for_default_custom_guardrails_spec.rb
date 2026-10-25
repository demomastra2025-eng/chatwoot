# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20261025120000_use_perplexity_decider_for_default_custom_guardrails')

RSpec.describe UsePerplexityDeciderForDefaultCustomGuardrails do
  let(:config_name) { 'CAPTAIN_CUSTOM_GUARDRAIL_MODEL' }
  let(:migration) { described_class.new }

  it 'switches only the exact previous default and is safe to replay' do
    config = upsert_installation_config(config_name, 'openai/gpt-6-luna-decisions')
    language = upsert_installation_config('CAPTAIN_LANGUAGE_DETECTION_MODEL', 'openai/gpt-6-luna-decisions')

    migration.up
    expect(config.reload.value).to eq('perplexity/pplx-decider-v1.2')
    expect(language.reload.value).to eq('openai/gpt-6-luna-decisions')
    expect { migration.up }.not_to(change { config.reload.updated_at })
  end

  [nil, '', 'openai/gpt-5.4-mini', 'inception/mercury-decide'].each do |value|
    it "keeps the explicit setting #{value.inspect}" do
      config = upsert_installation_config(config_name, value)

      expect { migration.up }.not_to(change { config.reload.updated_at })
      expect(config.reload.value).to eq(value)
    end
  end
end
