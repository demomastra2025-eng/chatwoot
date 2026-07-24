require 'rails_helper'
require Rails.root.join('db/migrate/20260723014714_upgrade_whatsapp_graph_api_version_to_v25')

RSpec.describe UpgradeWhatsappGraphApiVersionToV25 do
  let(:config) do
    InstallationConfig.find_or_initialize_by(name: 'WHATSAPP_API_VERSION').tap do |record|
      record.locked = false
      record.value = current_version
      record.save!
    end
  end

  before { config }

  context 'when the persisted Graph API version is below v25' do
    let(:current_version) { 'v24.0' }

    it 'upgrades the existing installation config to v25' do
      described_class.new.up

      expect(config.reload.value).to eq('v25.0')
    end
  end

  context 'when the persisted Graph API version is already current or newer' do
    let(:current_version) { 'v26.0' }

    it 'preserves the configured version' do
      described_class.new.up

      expect(config.reload.value).to eq('v26.0')
    end
  end

  context 'when the persisted Graph API version is malformed' do
    let(:current_version) { 'custom-version' }

    it 'leaves it unchanged for the health gate to report' do
      described_class.new.up

      expect(config.reload.value).to eq('custom-version')
    end
  end
end
