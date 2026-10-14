# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20261014102000_use_luna_decisions_for_default_custom_guardrails')

RSpec.describe UseLunaDecisionsForDefaultCustomGuardrails do
  let(:config_name) { 'CAPTAIN_CUSTOM_GUARDRAIL_MODEL' }
  let(:migration) { described_class.new }

  it 'updates only the exact old default and is safe to replay' do
    config = upsert_installation_config(config_name, 'openai/gpt-6-luna')
    moderation = upsert_installation_config('CAPTAIN_MODERATION_MODEL', 'openai/gpt-oss-safeguard-20b')

    migration.up
    expect(config.reload.value).to eq('openai/gpt-6-luna-decisions')
    expect(moderation.reload.value).to eq('openai/gpt-oss-safeguard-20b')
    expect { migration.up }.not_to(change { config.reload.updated_at })
  end

  [nil, '', 'openai/gpt-5.4-mini', 'openai/gpt-6-luna-decisions'].each do |value|
    it "preserves the explicit setting #{value.inspect}" do
      config = upsert_installation_config(config_name, value)

      expect { migration.up }.not_to(change { config.reload.updated_at })
      expect(config.reload.value).to eq(value)
    end
  end
end
