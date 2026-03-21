# frozen_string_literal: true

require 'rails_helper'

RSpec.describe InstallationConfig do
  it { is_expected.to validate_presence_of(:name) }

  describe 'serialized_value' do
    it 'keeps column defaults readable' do
      expect { described_class.column_defaults }.not_to raise_error
      expect(described_class.column_defaults['serialized_value']).to eq({}.with_indifferent_access)
    end

    it 'reads legacy YAML payloads stored inside jsonb strings' do
      config = described_class.create!(name: 'LEGACY_INSTALLATION_CONFIG')
      legacy_payload = { value: 'legacy-value' }.with_indifferent_access.to_yaml

      quoted_payload = described_class.connection.quote(legacy_payload)
      described_class.connection.execute(
        "UPDATE installation_configs SET serialized_value = #{quoted_payload} WHERE id = #{config.id}"
      )

      expect(config.reload.serialized_value).to eq({ value: 'legacy-value' }.with_indifferent_access)
      expect(config.value).to eq('legacy-value')
    end

    it 'writes new values as jsonb objects' do
      config = described_class.create!(name: 'JSONB_INSTALLATION_CONFIG')

      config.value = 'fresh-value'
      config.save!

      raw_type = described_class.connection.select_value(
        "select jsonb_typeof(serialized_value) from installation_configs where id = #{config.id}"
      )

      expect(raw_type).to eq('object')
      expect(config.reload.value).to eq('fresh-value')
    end
  end
end
