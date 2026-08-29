require 'rails_helper'

RSpec.describe Integrations::Medelement::Configuration do
  subject(:configuration) { described_class.new(hook: hook) }

  let(:hook) do
    instance_double(
      Integrations::Hook,
      id: 45,
      secret_settings: { 'integrator_key' => 'hook-integrator-key' },
      settings: {}
    )
  end

  describe '#integrator_key' do
    it 'uses the shared project integrator key when configured' do
      with_modified_env('MEDELEMENT_INTEGRATOR_KEY' => 'project-integrator-key') do
        expect(configuration.integrator_key).to eq('project-integrator-key')
      end
    end

    it 'falls back to the hook key for existing integrations' do
      with_modified_env('MEDELEMENT_INTEGRATOR_KEY' => nil) do
        expect(configuration.integrator_key).to eq('hook-integrator-key')
      end
    end
  end

  describe '#sync_services?' do
    it 'is enabled by default for existing hooks' do
      expect(configuration.sync_services?).to be(true)
    end

    it 'respects an explicit disabled setting' do
      allow(hook).to receive(:settings).and_return('sync_services' => false)

      expect(configuration.sync_services?).to be(false)
    end
  end

  describe '#receptions_sync_cron_expression' do
    it 'uses a fixed two-minute refresh in the configured timezone' do
      allow(hook).to receive(:settings).and_return('timezone' => 'UTC')

      expect(configuration.receptions_sync_cron_expression).to eq('*/2 * * * * UTC')
    end
  end

  describe '#contacts_sync_cron_expression' do
    it 'spreads bounded hourly contact batches deterministically across hooks' do
      expect(configuration.contacts_sync_cron_expression).to eq('45 * * * * Asia/Almaty')
    end
  end

  describe 'reception detail policy' do
    it 'uses bounded safe defaults' do
      expect(configuration.reception_detail_budget).to eq(50)
      expect(configuration.reception_detail_refresh_interval).to eq(6.hours)
    end

    it 'clamps unsafe configured values' do
      allow(hook).to receive(:settings).and_return(
        'reception_detail_budget' => 5000,
        'reception_detail_refresh_minutes' => 1
      )

      expect(configuration.reception_detail_budget).to eq(500)
      expect(configuration.reception_detail_refresh_interval).to eq(15.minutes)
    end
  end
end
