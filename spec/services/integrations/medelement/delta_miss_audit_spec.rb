require 'rails_helper'

RSpec.describe Integrations::Medelement::DeltaMissAudit do
  include ActiveSupport::Testing::TimeHelpers

  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }
  let(:audit) { described_class.new(hook: hook) }

  before do
    hook.update!(settings: hook.settings.merge('incremental_receptions_enabled' => true))
    Integrations::Medelement::SyncCursor.create!(
      hook: hook, name: 'receptions_delta', value: 1.minute.ago, last_success_at: Time.current
    )
  end

  def record_change
    audit.record_change!(
      reception_code: 'reception-1', change_marker: 'marker-1', kind: 'changed',
      changed_fields: %w[starts_at status]
    )
  end

  def complete_delta_poll!
    Integrations::Medelement::SyncCursor.find_by!(hook: hook, name: 'receptions_delta').update!(
      value: Time.current, last_success_at: Time.current, last_poll_at: Time.current
    )
  end

  it 'records one unexplained miss after a complete poll and the grace period' do
    record_change
    record_change
    travel 2.minutes + 1.second do
      complete_delta_poll!
      audit.resolve_candidates!(poll_completed_at: Time.current)
    end

    miss = Integrations::Medelement::DeltaMiss.find_by!(hook: hook)
    expect(miss).to have_attributes(classification: 'unexplained', kind: 'changed')
    expect(miss.changed_fields).to eq(%w[starts_at status])
    expect(Integrations::Medelement::DeltaMiss.where(hook: hook).count).to eq(1)
  end

  it 'classifies a recent successful own provider command separately' do
    Integrations::Medelement::ProviderCommand.create!(
      account: account, hook: hook, operation: 'remove_reception', status: 'succeeded',
      provider_reception_code: 'reception-1', idempotency_key: 'fake-command-1'
    )
    record_change
    travel 2.minutes + 1.second do
      complete_delta_poll!
      audit.resolve_candidates!(poll_completed_at: Time.current)
    end

    expect(Integrations::Medelement::DeltaMiss.find_by!(hook: hook).classification).to eq('own_api_change')
  end

  it 'does not record a miss for a matching delta marker' do
    record_change
    Integrations::Medelement::DeltaSeenReception.create!(
      hook: hook, reception_code: 'reception-1', change_marker: 'marker-1', processed_at: Time.current
    )
    travel 2.minutes + 1.second do
      complete_delta_poll!
      audit.resolve_candidates!(poll_completed_at: Time.current)
    end

    expect(Integrations::Medelement::DeltaMiss.where(hook: hook)).to be_empty
  end

  it 'does not create a candidate when the delta feature is off' do
    hook.update!(settings: hook.settings.merge('incremental_receptions_enabled' => false))
    record_change

    expect(Integrations::Medelement::DeltaMissCandidate.where(hook: hook)).to be_empty
  end

  it 'prunes only seen markers older than seven days' do
    old = Integrations::Medelement::DeltaSeenReception.create!(
      hook: hook, reception_code: 'old', change_marker: 'old', processed_at: 8.days.ago
    )
    recent = Integrations::Medelement::DeltaSeenReception.create!(
      hook: hook, reception_code: 'recent', change_marker: 'recent', processed_at: 6.days.ago
    )

    audit.prune_seen!

    expect(Integrations::Medelement::DeltaSeenReception.exists?(old.id)).to be(false)
    expect(Integrations::Medelement::DeltaSeenReception.exists?(recent.id)).to be(true)
  end

  it 'logarithmically increases full sweep interval on clean sweeps and resets to 2 minutes on errors or misses' do
    schedule_service = instance_double(Integrations::Medelement::CronScheduleService, sync!: true)
    allow(Integrations::Medelement::CronScheduleService).to receive(:new).with(hook: hook).and_return(schedule_service)
    config = Integrations::Medelement::Configuration.new(hook: hook)

    [4, 8, 15, 30, 60, 60].each do |expected_minutes|
      Integrations::Medelement::SyncCursor.find_by!(hook: hook, name: 'receptions_delta').update!(
        last_poll_at: Time.current, last_success_at: Time.current
      )
      audit.record_full_sweep_result!
      expect(config.receptions_full_sweep_interval_minutes).to eq(expected_minutes)
    end

    record_change
    travel 2.minutes + 1.second do
      complete_delta_poll!
      audit.resolve_candidates!(poll_completed_at: Time.current)
    end
    expect(config.receptions_full_sweep_interval_minutes).to eq(2)

    Integrations::Medelement::SyncCursor.find_by!(hook: hook, name: 'receptions_delta').update!(
      last_poll_at: Time.current, last_success_at: Time.current
    )
    audit.record_full_sweep_result!
    expect(config.receptions_full_sweep_interval_minutes).to eq(4)

    error = Integrations::Medelement::Client::ApiError.new('Delta forbidden', status: 401)
    audit.record_poll_error!(error)
    expect(config.receptions_full_sweep_interval_minutes).to eq(2)
    expect(
      Integrations::Medelement::DeltaMiss.where(
        hook: hook, kind: 'poll_error', classification: 'provider_error', reception_code: 'poll_error:http_401'
      )
    ).to exist
  end

  it 'keeps a candidate pending while a full sync finishes ahead of a paused delta cursor' do
    cursor = Integrations::Medelement::SyncCursor.find_by!(hook: hook, name: 'receptions_delta')
    cursor.update!(value: 25.minutes.ago, last_success_at: 25.minutes.ago,
                   last_poll_at: Time.current, current_interval_seconds: 15)
    run = Integrations::Medelement::SyncRun.create!(
      hook: hook, account: account, trigger: 'scheduled', status: 'running', started_at: 20.minutes.ago
    )
    audit.record_change!(reception_code: 'reception-1', change_marker: 'marker-1', kind: 'changed',
                         changed_fields: ['status'], full_sweep_run: run)

    travel 3.minutes do
      audit.record_full_sweep_result!
      expect(Integrations::Medelement::DeltaMiss.where(hook: hook)).to be_empty
      expect(Integrations::Medelement::DeltaMissCandidate.where(hook: hook).count).to eq(1)

      Integrations::Medelement::DeltaSeenReception.create!(
        hook: hook, reception_code: 'reception-1', change_marker: 'marker-1', processed_at: Time.current
      )
      complete_delta_poll!
      expect(audit.resolve_candidates!(poll_completed_at: Time.current)).to eq(0)
    end

    expect(Integrations::Medelement::DeltaMiss.where(hook: hook)).to be_empty
    expect(Integrations::Medelement::DeltaMissCandidate.where(hook: hook)).to be_empty
  end

  it 'ignores source creation metadata without losing real fields from a mixed change' do
    fields = ['custom_attributes.medelement_source_created_at']
    audit.record_change!(reception_code: 'metadata-only', change_marker: 'marker-1', kind: 'changed', changed_fields: fields)
    expect(Integrations::Medelement::DeltaMissCandidate.where(hook: hook)).to be_empty

    audit.record_change!(reception_code: 'real-change', change_marker: 'marker-2', kind: 'changed',
                         changed_fields: fields + ['status'])
    expect(Integrations::Medelement::DeltaMissCandidate.find_by!(hook: hook).changed_fields).to eq(['status'])
  end

  it 'discards an already queued metadata-only candidate after a completed delta poll' do
    Integrations::Medelement::DeltaMissCandidate.create!(
      hook: hook, reception_code: 'metadata-only', change_marker: 'marker-1', kind: 'changed',
      detected_at: 3.minutes.ago, changed_fields: ['custom_attributes.medelement_source_created_at']
    )
    complete_delta_poll!

    expect(audit.resolve_candidates!(poll_completed_at: Time.current)).to eq(0)
    expect(Integrations::Medelement::DeltaMiss.where(hook: hook)).to be_empty
    expect(Integrations::Medelement::DeltaMissCandidate.where(hook: hook)).to be_empty
  end

  it 'treats a 12-minute-old delta cursor as healthy during off-hours and the 07:05 morning transition' do
    schedule_service = instance_double(Integrations::Medelement::CronScheduleService, sync!: true)
    allow(Integrations::Medelement::CronScheduleService).to receive(:new).with(hook: hook).and_return(schedule_service)
    Integrations::Medelement::SyncCursor.create!(
      hook: hook,
      name: Integrations::Medelement::Configuration::FULL_SWEEP_BACKOFF_CURSOR_NAME,
      current_interval_seconds: 3600
    )

    [
      ActiveSupport::TimeZone['Asia/Almaty'].parse('2026-11-02 02:30:00'),
      ActiveSupport::TimeZone['Asia/Almaty'].parse('2026-11-02 07:05:00')
    ].each do |check_time|
      travel_to check_time do
        Integrations::Medelement::SyncCursor.find_by!(hook: hook, name: 'receptions_delta').update!(
          value: 12.minutes.ago,
          last_poll_at: 12.minutes.ago,
          last_success_at: 12.minutes.ago
        )

        audit.record_full_sweep_result!

        backoff = Integrations::Medelement::SyncCursor.find_by!(
          hook: hook,
          name: Integrations::Medelement::Configuration::FULL_SWEEP_BACKOFF_CURSOR_NAME
        )
        expect(backoff.current_interval_seconds).to eq(3600)
      end
    end

    travel_to ActiveSupport::TimeZone['Asia/Almaty'].parse('2026-11-02 14:00:00') do
      Integrations::Medelement::SyncCursor.find_by!(hook: hook, name: 'receptions_delta').update!(
        value: 12.minutes.ago,
        last_poll_at: 12.minutes.ago,
        last_success_at: 12.minutes.ago
      )

      audit.record_full_sweep_result!

      backoff = Integrations::Medelement::SyncCursor.find_by!(
        hook: hook,
        name: Integrations::Medelement::Configuration::FULL_SWEEP_BACKOFF_CURSOR_NAME
      )
      expect(backoff.current_interval_seconds).to eq(120)
    end
  end
end
