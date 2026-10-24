require 'rails_helper'

RSpec.describe Integrations::Medelement::DeltaProbeService do
  include ActiveSupport::Testing::TimeHelpers

  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:flag) { false }
  let(:hook) do
    create(:integrations_hook, :medelement, account: account).tap do |record|
      record.update!(settings: record.settings.merge('incremental_receptions_enabled' => flag)) unless flag.nil?
    end
  end
  let(:client) { instance_double(Integrations::Medelement::Client, receptions_by_update_date: []) }
  let(:cron_service) { instance_double(Integrations::Medelement::CronScheduleService, sync!: true) }
  let(:service) { described_class.new(hook: hook, client: client) }

  def api_error(status = nil, message = 'provider failed')
    Integrations::Medelement::Client::ApiError.new(message, status: status)
  end

  def probe_result
    hook.reload.settings[described_class::RESULT_KEY]
  end

  def flag_value
    hook.reload.settings['incremental_receptions_enabled']
  end

  before do
    hook
    allow(Integrations::Medelement::CronScheduleService).to receive(:new).and_return(cron_service)
  end

  it 'switches fast sync on after a valid answer and syncs the cron jobs so the delta job exists' do
    expect(service.perform).to eq('available')

    expect(flag_value).to be(true)
    expect(Integrations::Medelement::CronScheduleService).to have_received(:new).with(hook: hook)
    expect(cron_service).to have_received(:sync!)
    expect(probe_result).to include('outcome' => 'available', 'checked_at' => be_present)
    expect(probe_result).not_to have_key('error_code')
  end

  it 'asks only for the changes of the last hour, in the clinic time zone' do
    travel_to(Time.utc(2026, 10, 24, 2, 0)) { service.perform }

    expect(client).to have_received(:receptions_by_update_date).with(update_date_from: '24.10.2026 06:00')
  end

  it 'applies nothing and leaves the delta cursor and seen receptions alone' do
    service.perform

    expect(Integrations::Medelement::SyncCursor.where(hook: hook)).to be_empty
    expect(Integrations::Medelement::DeltaSeenReception.where(hook: hook)).to be_empty
    expect(account.scheduling_appointments).to be_empty
  end

  it 'asks with the short retry profile so a failing provider does not hold the worker' do
    allow(Integrations::Medelement::Client).to receive(:new).and_return(client)

    described_class.new(hook: hook).perform

    expect(Integrations::Medelement::Client).to have_received(:new).with(
      configuration: an_instance_of(Integrations::Medelement::Configuration), retry_profile: :command
    )
  end

  it 'starts the full-sweep backoff over when it switches fast sync back on' do
    backoff = Integrations::Medelement::SyncCursor.create!(
      hook: hook, name: Integrations::Medelement::Configuration::FULL_SWEEP_BACKOFF_CURSOR_NAME,
      current_interval_seconds: 60.minutes.to_i
    )

    service.perform

    expect(backoff.reload.current_interval_seconds).to eq(Integrations::Medelement::DeltaMissAudit::DEFAULT_SWEEP_SECONDS)
  end

  context 'when fast sync is already on' do
    let(:flag) { true }

    it 'keeps the flag and the backoff, and still syncs the cron jobs' do
      backoff = Integrations::Medelement::SyncCursor.create!(
        hook: hook, name: Integrations::Medelement::Configuration::FULL_SWEEP_BACKOFF_CURSOR_NAME,
        current_interval_seconds: 30.minutes.to_i
      )

      service.perform

      expect(flag_value).to be(true)
      expect(backoff.reload.current_interval_seconds).to eq(30.minutes.to_i)
      expect(cron_service).to have_received(:sync!).once
      expect(probe_result).to include('outcome' => 'available')
    end
  end

  context 'when the flag was never set (on by default)' do
    let(:flag) { nil }

    it 'leaves the settings without a flag and records the result' do
      service.perform

      expect(hook.reload.settings).not_to have_key('incremental_receptions_enabled')
      expect(probe_result).to include('outcome' => 'available')
    end
  end

  [401, 403, 404].each do |status|
    context "when MedElement answers #{status}" do
      let(:flag) { true }

      before { allow(client).to receive(:receptions_by_update_date).and_raise(api_error(status)) }

      it 'switches fast sync off, syncs the cron jobs and records the code' do
        expect(service.perform).to eq('unavailable')

        expect(flag_value).to be(false)
        expect(cron_service).to have_received(:sync!)
        expect(probe_result).to include('outcome' => 'unavailable', 'error_code' => "http_#{status}")
      end
    end
  end

  context 'when fast sync is already off and the endpoint is still refused' do
    before { allow(client).to receive(:receptions_by_update_date).and_raise(api_error(403)) }

    it 'stays off and syncs the cron jobs again so no delta job is left behind' do
      service.perform

      expect(flag_value).to be(false)
      expect(cron_service).to have_received(:sync!)
    end
  end

  flags = [true, false]
  {
    'a timeout' => [nil, 'api_error'],
    'a 500' => [500, 'http_500'],
    'a 503' => [503, 'http_503'],
    'a 429' => [429, 'http_429'],
    'a 408' => [408, 'http_408']
  }.each do |label, (status, code)|
    flags.each do |before_flag|
      context "when the probe meets #{label} and the flag is #{before_flag}" do
        let(:flag) { before_flag }

        before { allow(client).to receive(:receptions_by_update_date).and_raise(api_error(status)) }

        it 'changes nothing but the recorded result' do
          expect(service.perform).to eq('transient_error')

          expect(flag_value).to be(before_flag)
          expect(cron_service).not_to have_received(:sync!)
          expect(probe_result).to include('outcome' => 'transient_error', 'error_code' => code)
        end
      end
    end
  end

  it 'treats a busy request slot as transient' do
    allow(client).to receive(:receptions_by_update_date).and_raise(Integrations::Medelement::Client::RateLimitedError.new)

    expect(service.perform).to eq('transient_error')
    expect(flag_value).to be(false)
    expect(probe_result).to include('error_code' => 'rate_limited_error')
  end

  it 'does not switch anything on a rejected request (400)' do
    allow(client).to receive(:receptions_by_update_date).and_raise(api_error(400))

    expect(service.perform).to eq('error')
    expect(flag_value).to be(false)
    expect(cron_service).not_to have_received(:sync!)
    expect(probe_result).to include('outcome' => 'error', 'error_code' => 'http_400')
  end

  it 'does not switch anything on an answer of another organization' do
    allow(client).to receive(:receptions_by_update_date)
      .and_raise(Integrations::Medelement::ProviderScope::MismatchError, 'another organization')

    expect(service.perform).to eq('error')
    expect(flag_value).to be(false)
    expect(probe_result).to include('outcome' => 'error', 'error_code' => 'provider_scope_mismatch')
  end

  it 'replaces the previous result with the latest one' do
    travel_to(Time.utc(2026, 10, 24, 2, 0)) { service.perform }
    allow(client).to receive(:receptions_by_update_date).and_raise(api_error(502))
    travel_to(Time.utc(2026, 10, 24, 14, 0)) { service.perform }

    expect(probe_result).to eq(
      'checked_at' => '2026-10-24T14:00:00Z', 'outcome' => 'transient_error', 'error_code' => 'http_502'
    )
  end

  it 'does not overwrite a settings edit made while the probe was running' do
    allow(client).to receive(:receptions_by_update_date) do
      # rubocop:disable Rails/SkipsModelValidations
      Integrations::Hook.where(id: hook.id).update_all("settings = settings || '{\"receptions_days_back\": 2}'::jsonb")
      # rubocop:enable Rails/SkipsModelValidations
      []
    end

    service.perform

    expect(hook.reload.settings).to include('receptions_days_back' => 2, 'incremental_receptions_enabled' => true)
  end

  describe 'hooks that are not probed' do
    it 'skips a disabled hook' do
      hook.update!(status: 'disabled')

      expect(service.perform).to be_nil
      expect(client).not_to have_received(:receptions_by_update_date)
    end

    it 'skips a hook that does not sync receptions' do
      hook.update!(settings: hook.settings.merge('sync_receptions' => false))

      expect(service.perform).to be_nil
      expect(client).not_to have_received(:receptions_by_update_date)
    end

    it 'skips a hook whose probe is switched off, keeping its flag as it is' do
      hook.update!(settings: hook.settings.merge('delta_probe_enabled' => false))

      expect(service.perform).to be_nil
      expect(client).not_to have_received(:receptions_by_update_date)
      expect(flag_value).to be(false)
      expect(probe_result).to be_nil
    end

    it 'skips a hook whose account lost the scheduling feature' do
      account.disable_features!('scheduling')

      expect(service.perform).to be_nil
      expect(client).not_to have_received(:receptions_by_update_date)
    end
  end
end
