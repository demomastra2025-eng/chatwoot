require 'rails_helper'

RSpec.describe Internal::CheckNewVersionsJob do
  subject(:job) { described_class.perform_now }

  let(:reconsile_premium_config_service) { instance_double(Internal::ReconcilePlanConfigService) }

  before do
    allow(Internal::ReconcilePlanConfigService).to receive(:new).and_return(reconsile_premium_config_service)
    allow(reconsile_premium_config_service).to receive(:perform)
    allow(Rails.env).to receive(:production?).and_return(true)
  end

  it 'updates the plan info' do
    data = { 'version' => '1.2.3', 'plan' => 'enterprise', 'plan_quantity' => 1, 'chatwoot_support_website_token' => '123',
             'chatwoot_support_identifier_hash' => '123', 'chatwoot_support_script_url' => '123' }
    allow(ChatwootHub).to receive(:sync_with_hub).and_return(data)
    job
    expect(InstallationConfig.find_by(name: 'INSTALLATION_PRICING_PLAN').value).to eq 'enterprise'
    expect(InstallationConfig.find_by(name: 'INSTALLATION_PRICING_PLAN_QUANTITY').value).to eq 1
    expect(InstallationConfig.find_by(name: 'CHATWOOT_SUPPORT_WEBSITE_TOKEN').value).to eq '123'
    expect(InstallationConfig.find_by(name: 'CHATWOOT_SUPPORT_IDENTIFIER_HASH').value).to eq '123'
    expect(InstallationConfig.find_by(name: 'CHATWOOT_SUPPORT_SCRIPT_URL').value).to eq '123'
  end

  context 'when the installation did not opt in to the hub' do
    before { allow(RestClient).to receive(:post) }

    it 'sends nothing to the hub, and still puts a self-hosted installation on the enterprise plan' do
      InstallationConfig.where(name: %w[INSTALLATION_PRICING_PLAN INSTALLATION_PRICING_PLAN_QUANTITY]).destroy_all

      with_modified_env(ENABLE_CHATWOOT_HUB_SYNC: nil) { job }

      expect(RestClient).not_to have_received(:post)
      expect(InstallationConfig.find_by(name: 'INSTALLATION_PRICING_PLAN').value).to eq 'enterprise'
      expect(InstallationConfig.find_by(name: 'INSTALLATION_PRICING_PLAN_QUANTITY').value).to eq 1
      expect(reconsile_premium_config_service).to have_received(:perform)
    end

    it 'does not touch the support settings, which come from the hub' do
      InstallationConfig.where(name: 'CHATWOOT_SUPPORT_WEBSITE_TOKEN').destroy_all

      with_modified_env(ENABLE_CHATWOOT_HUB_SYNC: nil) { job }

      expect(InstallationConfig.find_by(name: 'CHATWOOT_SUPPORT_WEBSITE_TOKEN')&.value).to be_blank
    end

    it 'leaves the plan of a cloud installation alone, since the cloud takes it from the hub' do
      allow(ChatwootApp).to receive(:chatwoot_cloud?).and_return(true)
      InstallationConfig.where(name: 'INSTALLATION_PRICING_PLAN').destroy_all

      with_modified_env(ENABLE_CHATWOOT_HUB_SYNC: nil) { job }

      expect(InstallationConfig.find_by(name: 'INSTALLATION_PRICING_PLAN')).to be_nil
    end
  end

  it 'calls Internal::ReconcilePlanConfigService' do
    data = { 'version' => '1.2.3' }
    allow(ChatwootHub).to receive(:sync_with_hub).and_return(data)
    job
    expect(reconsile_premium_config_service).to have_received(:perform)
  end
end
