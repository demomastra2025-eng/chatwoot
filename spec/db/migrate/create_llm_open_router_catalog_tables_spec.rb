# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20260531111534_create_llm_open_router_catalog_tables')

RSpec.describe CreateLlmOpenRouterCatalogTables do
  describe '#legacy_payload' do
    it 'unwraps InstallationConfig serialized value wrappers before backfill' do
      InstallationConfig.where(name: 'CAPTAIN_OPENROUTER_MODEL_CATALOG').delete_all
      InstallationConfig.create!(
        name: 'CAPTAIN_OPENROUTER_MODEL_CATALOG',
        value: {
          'models' => {
            'legacy/model' => {
              'provider' => 'openrouter',
              'type' => 'chat'
            }
          },
          'last_refreshed_at' => '2026-05-31T10:00:00Z'
        }
      )

      payload = described_class.new.send(:legacy_payload, 'CAPTAIN_OPENROUTER_MODEL_CATALOG')

      expect(payload).to include(
        'models' => include(
          'legacy/model' => include('provider' => 'openrouter', 'type' => 'chat')
        ),
        'last_refreshed_at' => '2026-05-31T10:00:00Z'
      )
    end
  end
end
