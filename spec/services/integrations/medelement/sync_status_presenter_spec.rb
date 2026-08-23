require 'rails_helper'

describe Integrations::Medelement::SyncStatusPresenter do
  let(:account) { create(:account) }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }
  let(:run) do
    Integrations::Medelement::SyncRun.create!(account: account, hook: hook, trigger: 'manual', status: 'partial')
  end

  before do
    account.enable_features!('scheduling')
    allow(Sidekiq::Cron::Job).to receive(:find).and_return(nil)
  end

  def create_specialist_conflict(sequence)
    resource = create(
      :scheduling_resource,
      account: account,
      custom_attributes: { 'medelement_specialist_code' => "specialist-#{sequence}" }
    )
    Integrations::Medelement::ConflictTracker.new(sync_run: run).record!(
      phase: 'specialists',
      entity_type: 'specialist',
      conflict_type: 'invalid_specialist',
      entity_key: "specialist-#{sequence}",
      details: { resource_id: resource.id, specialist_code: "specialist-#{sequence}" }
    )
  end

  def select_query_count(&)
    count = 0
    subscriber = lambda do |_name, _started, _finished, _unique_id, payload|
      next if payload[:name] == 'SCHEMA' || payload[:cached]
      next unless payload[:sql].to_s.match?(/\ASELECT\b/i)

      count += 1
    end
    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record', &)
    count
  end

  it 'preloads entity cards with a bounded query count' do
    create_specialist_conflict(1)
    one_conflict_queries = select_query_count { described_class.new(hook: hook).payload }
    9.times { |index| create_specialist_conflict(index + 2) }

    many_conflicts_queries = select_query_count { described_class.new(hook: hook).payload }

    expect(many_conflicts_queries).to be <= one_conflict_queries + 1
  end

  it 'resolves a legacy appointment by external reference when the custom code is absent' do
    appointment = create(
      :scheduling_appointment,
      account: account,
      external_ref: 'medelement:reception:legacy-reception',
      custom_attributes: {}
    )
    Integrations::Medelement::ConflictTracker.new(sync_run: run).record!(
      phase: 'receptions',
      entity_type: 'reception',
      conflict_type: 'invalid_reception',
      entity_key: 'legacy-reception',
      details: { reception_code: 'legacy-reception' }
    )

    conflict = described_class.new(hook: hook).payload[:conflicts].first

    expect(conflict.dig(:entity_context, :appointment, :id)).to eq(appointment.id)
  end

  it 'reports the latest persisted result for every phase instead of only the latest run' do
    specialists_run = Integrations::Medelement::SyncRun.create!(
      account: account,
      hook: hook,
      trigger: 'scheduled',
      status: 'succeeded',
      requested_phases: ['specialists'],
      completed_at: 2.hours.ago,
      phase_results: {
        'specialists' => {
          'status' => 'succeeded',
          'provider_count' => 3,
          'completed_at' => 2.hours.ago.iso8601
        }
      }
    )
    receptions_run = Integrations::Medelement::SyncRun.create!(
      account: account,
      hook: hook,
      trigger: 'scheduled',
      status: 'succeeded',
      requested_phases: ['receptions'],
      completed_at: 1.hour.ago,
      phase_results: {
        'receptions' => { 'status' => 'succeeded', 'imported_count' => 2, 'completed_at' => 1.hour.ago.iso8601 }
      }
    )

    payload = described_class.new(hook: hook).payload

    expect(payload.dig(:phase_statuses, 'specialists')).to include(
      run_id: specialists_run.id,
      status: 'succeeded',
      result: hash_including('provider_count' => 3)
    )
    expect(payload.dig(:phase_statuses, 'receptions')).to include(
      run_id: receptions_run.id,
      status: 'succeeded',
      result: hash_including('imported_count' => 2)
    )
  end
end
