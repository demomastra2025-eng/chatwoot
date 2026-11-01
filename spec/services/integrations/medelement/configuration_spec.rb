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

  describe '#throttle_ms' do
    it 'defaults to the 200 ms spacing the provider allows' do
      expect(configuration.throttle_ms).to eq(200)
    end

    it 'keeps a longer pause that a hook asks for' do
      allow(hook).to receive(:settings).and_return('throttle_ms' => 500)

      expect(configuration.throttle_ms).to eq(500)
    end

    [0, 1, 199, -5].each do |too_short|
      it "never goes below the provider's limit of five requests per second, whatever a hook saved (#{too_short})" do
        allow(hook).to receive(:settings).and_return('throttle_ms' => too_short)

        expect(configuration.throttle_ms).to eq(200)
      end
    end
  end

  describe '#global_throttle_ms' do
    it 'defaults to 125 ms cross-clinic background spacing and clamps shorter values' do
      expect(configuration.global_throttle_ms).to eq(125)

      allow(hook).to receive(:settings).and_return('global_throttle_ms' => 50)
      expect(configuration.global_throttle_ms).to eq(125)

      allow(hook).to receive(:settings).and_return('global_throttle_ms' => 250)
      expect(configuration.global_throttle_ms).to eq(250)
    end
  end

  describe 'request volume settings' do
    it 'starts with a conservative shared budget and protected live share' do
      expect(configuration.request_budget_per_minute).to eq(30)
      expect(configuration.live_reserve_per_minute).to eq(10)
      expect(configuration.rate_alert_threshold_per_hour).to eq(3)
    end

    it 'clamps the live reserve below the configured budget' do
      settings = { 'request_budget_per_minute' => 12, 'live_reserve_per_minute' => 20,
                   'rate_alert_threshold_per_hour' => 2 }
      allow(hook).to receive(:settings).and_return(settings)

      expect(configuration.request_budget_per_minute).to eq(12)
      expect(configuration.live_reserve_per_minute).to eq(11)
      expect(configuration.rate_alert_threshold_per_hour).to eq(2)
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
    it 'staggers two-minute refreshes deterministically by hook id in the configured timezone' do
      allow(hook).to receive(:settings).and_return('timezone' => 'UTC')
      expect(configuration.receptions_sync_cron_expression).to eq('*/2 * * * * UTC')

      odd_hook = instance_double(Integrations::Hook, id: 46, secret_settings: {}, settings: { 'timezone' => 'UTC' })
      expect(described_class.new(hook: odd_hook).receptions_sync_cron_expression).to eq('1-59/2 * * * * UTC')
    end

    it 'staggers hourly and daily full sweeps deterministically off minute :00' do
      expect(configuration.receptions_full_sweep_interval_minutes).to eq(2)
      allow(hook).to receive(:settings).and_return('receptions_full_sweep_interval_minutes' => 60)

      expect(configuration.receptions_sync_cron_expression).to eq('18 */1 * * * Asia/Almaty')

      allow(hook).to receive(:settings).and_return('receptions_full_sweep_interval_minutes' => 1440)
      expect(configuration.receptions_sync_cron_expression).to eq('18 9 * * * Asia/Almaty')
    end
  end

  describe 'incremental reception settings' do
    it 'defaults the feature on and the interval to sixty seconds, while respecting an explicit false' do
      expect(configuration.incremental_receptions_enabled?).to be(true)
      expect(configuration.incremental_receptions_interval_seconds).to eq(60)

      allow(hook).to receive(:settings).and_return('incremental_receptions_enabled' => false)
      expect(configuration.incremental_receptions_enabled?).to be(false)
    end

    it 'lets the daily probe run unless it is switched off for the clinic' do
      expect(configuration.delta_probe_enabled?).to be(true)

      allow(hook).to receive(:settings).and_return('delta_probe_enabled' => false)
      expect(configuration.delta_probe_enabled?).to be(false)
    end

    it 'applies stale statuses from the nightly run only for a clinic that has been switched on' do
      expect(configuration.stale_status_apply_enabled?).to be(false)

      allow(hook).to receive(:settings).and_return('stale_status_apply_enabled' => true)
      expect(configuration.stale_status_apply_enabled?).to be(true)

      allow(hook).to receive(:settings).and_return('stale_status_apply_enabled' => false)
      expect(configuration.stale_status_apply_enabled?).to be(false)
    end

    it 'accepts only the supported intervals and scopes daytime vs staggered night delta crons' do
      allow(hook).to receive(:settings).and_return(
        'incremental_receptions_enabled' => true,
        'incremental_receptions_interval_seconds' => 120
      )
      expect(configuration.receptions_delta_cron_expression).to eq('*/2 7-20 * * * Asia/Almaty')
      expect(configuration.receptions_delta_night_cron_expression).to eq('0,15,30,45 0-6,21-23 * * * Asia/Almaty')

      allow(hook).to receive(:settings).and_return(
        'incremental_receptions_enabled' => true,
        'incremental_receptions_interval_seconds' => 60,
        'night_delta_throttle_enabled' => false
      )
      expect(configuration.receptions_delta_cron_expression).to eq('* * * * * Asia/Almaty')
      expect(configuration.receptions_delta_night_cron_expression).to be_nil

      allow(hook).to receive(:settings).and_return('incremental_receptions_interval_seconds' => 11)
      expect(configuration.incremental_receptions_interval_seconds).to eq(60)
    end

    it 'detects clinic off-hours (21:00..06:59) in the configured timezone and scales effective interval' do
      daytime = ActiveSupport::TimeZone['Asia/Almaty'].parse('2026-11-02 10:30:00')
      nighttime = ActiveSupport::TimeZone['Asia/Almaty'].parse('2026-11-02 22:15:00')

      expect(configuration.off_hours?(daytime)).to be(false)
      expect(configuration.effective_incremental_receptions_interval_seconds(daytime)).to eq(60)

      expect(configuration.off_hours?(nighttime)).to be(true)
      expect(configuration.effective_incremental_receptions_interval_seconds(nighttime)).to eq(900)
    end
  end

  describe 'hook setting validation' do
    let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
    let(:real_hook) { create(:integrations_hook, :medelement, account: account) }

    it 'rejects unsupported delta and full sweep intervals' do
      expect(real_hook.update(settings: real_hook.settings.merge('incremental_receptions_interval_seconds' => 11))).to be(false)
      expect(real_hook.update(settings: real_hook.settings.merge('receptions_full_sweep_interval_minutes' => 3))).to be(false)
    end

    it 'uses the adaptive full sweep backoff cursor when incremental sync is enabled' do
      Integrations::Medelement::SyncCursor.create!(
        hook: real_hook,
        name: 'receptions_full_sweep_backoff',
        current_interval_seconds: 900
      )
      real_config = described_class.new(hook: real_hook)

      expected_offset = ((real_hook.id * 7) + 3) % 15
      expected_minutes = [0, 15, 30, 45].map { |m| (m + expected_offset) % 60 }.sort.join(',')
      expect(real_config.receptions_full_sweep_interval_minutes).to eq(15)
      expect(real_config.receptions_sync_cron_expression).to eq("#{expected_minutes} * * * * Asia/Almaty")
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
