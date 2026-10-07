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

    it 'keeps the default full sweep and accepts the configured longer intervals' do
      expect(configuration.receptions_full_sweep_interval_minutes).to eq(2)
      allow(hook).to receive(:settings).and_return('receptions_full_sweep_interval_minutes' => 60)

      expect(configuration.receptions_sync_cron_expression).to eq('0 */1 * * * Asia/Almaty')
    end
  end

  describe 'incremental reception settings' do
    it 'defaults the feature off and the interval to sixty seconds' do
      expect(configuration.incremental_receptions_enabled?).to be(false)
      expect(configuration.incremental_receptions_interval_seconds).to eq(60)
    end

    it 'accepts only the supported intervals and uses minute cron when appropriate' do
      allow(hook).to receive(:settings).and_return(
        'incremental_receptions_enabled' => true,
        'incremental_receptions_interval_seconds' => 120
      )
      expect(configuration.receptions_delta_cron_expression).to eq('*/2 * * * * Asia/Almaty')

      allow(hook).to receive(:settings).and_return('incremental_receptions_interval_seconds' => 11)
      expect(configuration.incremental_receptions_interval_seconds).to eq(60)
    end
  end

  describe 'hook setting validation' do
    let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
    let(:real_hook) { create(:integrations_hook, :medelement, account: account) }

    it 'rejects unsupported delta and full sweep intervals' do
      expect(real_hook.update(settings: real_hook.settings.merge('incremental_receptions_interval_seconds' => 11))).to be(false)
      expect(real_hook.update(settings: real_hook.settings.merge('receptions_full_sweep_interval_minutes' => 3))).to be(false)
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
