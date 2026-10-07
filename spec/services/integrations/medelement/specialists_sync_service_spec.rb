require 'rails_helper'

RSpec.describe Integrations::Medelement::SpecialistsSyncService do
  let(:expected_default_rules) do
    [
      [0, 9 * 60, 15 * 60, false],
      [1, 9 * 60, 18 * 60, true],
      [2, 9 * 60, 18 * 60, true],
      [3, 9 * 60, 18 * 60, true],
      [4, 9 * 60, 18 * 60, true],
      [5, 9 * 60, 18 * 60, true],
      [6, 9 * 60, 15 * 60, true]
    ]
  end
  let(:account) { create(:account) }
  let(:client) { instance_double(Integrations::Medelement::Client) }
  let(:configuration) do
    instance_double(
      Integrations::Medelement::Configuration,
      time_zone: 'Asia/Almaty'
    )
  end

  before do
    allow(client).to receive(:specialists).and_return(
      [
        {
          'specialistCode' => '27492901726817790',
          'userName' => 'Сералиева Гульшат',
          'receptionTime' => 20,
          'isSchedulePublished' => 1,
          'cabinets' => [
            {
              'companyCabinetCode' => '37413011726129875',
              'cabinetName' => 'УЗИ ( кб. №14 )'
            }
          ]
        }
      ]
    )
  end

  it 'creates default work rules for imported specialists so they can accept manual bookings' do
    expect do
      described_class.new(account: account, client: client, configuration: configuration).perform
    end.to change(account.scheduling_resources, :count).by(1)
                                                       .and change(account.scheduling_work_rules, :count).by(7)

    resource = account.scheduling_resources.last

    expect(resource.work_rules.order(:weekday).pluck(:weekday, :start_minute, :end_minute, :active)).to eq(expected_default_rules)
    expect(resource.custom_attributes['medelement_default_work_rules_seeded_at']).to be_present
    expect(resource.timezone).to eq('Asia/Almaty')
    expect(resource).to be_active
    expect(resource.custom_attributes['medelement_specialist_code']).to eq('27492901726817790')
    expect(resource.custom_attributes['medelement_schedule_published']).to eq(1)
    expect(client).to have_received(:specialists).twice
  end

  it 'stores a large numeric provider code as a string and accepts numeric and string publication flags' do
    allow(client).to receive(:specialists).and_return(
      [
        { 'specialistCode' => 9_007_199_254_740_993, 'userName' => 'Synthetic One', 'isSchedulePublished' => 1 },
        { 'specialistCode' => '9007199254740994', 'userName' => 'Synthetic Two', 'isSchedulePublished' => 0 },
        { 'specialistCode' => '9007199254740995', 'userName' => 'Synthetic Three', 'isSchedulePublished' => '1' }
      ]
    )

    expect(described_class.new(account: account, client: client, configuration: configuration).perform)
      .to include(imported_count: 3)
    resources = account.scheduling_resources.index_by { |item| item.custom_attributes['medelement_specialist_code'] }
    expect(resources.keys).to contain_exactly('9007199254740993', '9007199254740994', '9007199254740995')
    expect(resources['9007199254740993']).to be_active
    expect(resources['9007199254740994']).not_to be_active
    expect(resources['9007199254740995']).to be_active
  end

  it 'reports provider inventory, local-only resources, and linked specialists missing from the provider response' do
    account.enable_features!('scheduling')
    hook = create(:integrations_hook, :medelement, account: account)
    sync_run = Integrations::Medelement::SyncRun.create!(account: account, hook: hook)
    missing_resource = create(
      :scheduling_resource,
      account: account,
      name: 'Previously linked specialist',
      custom_attributes: {
        'medelement_specialist_code' => 'missing-from-provider',
        'medelement_last_seen_at' => 1.day.ago.iso8601
      }
    )
    create(:scheduling_resource, account: account, name: 'One Link only specialist', custom_attributes: {})

    result = described_class.new(
      account: account,
      client: client,
      configuration: configuration,
      conflict_tracker: Integrations::Medelement::ConflictTracker.new(sync_run: sync_run)
    ).perform

    expect(result).to include(
      provider_count: 1,
      imported_count: 1,
      skipped_count: 0,
      not_returned_count: 1,
      local_unlinked_count: 1
    )
    expect(
      Integrations::Medelement::SyncConflict.find_by!(
        account: account,
        hook: hook,
        conflict_type: 'specialist_not_returned'
      ).details
    ).to include('resource_id' => missing_resource.id, 'specialist_code' => 'missing-from-provider')
  end

  it 'does not report a coded malformed specialist as absent from the provider response' do
    account.enable_features!('scheduling')
    hook = create(:integrations_hook, :medelement, account: account)
    sync_run = Integrations::Medelement::SyncRun.create!(account: account, hook: hook)
    create(
      :scheduling_resource,
      account: account,
      custom_attributes: { 'medelement_specialist_code' => 'coded-without-name' }
    )
    malformed_rows = [{ 'specialistCode' => 'coded-without-name' }]
    allow(client).to receive(:specialists).and_return(malformed_rows)

    result = described_class.new(
      account: account,
      client: client,
      configuration: configuration,
      conflict_tracker: Integrations::Medelement::ConflictTracker.new(sync_run: sync_run)
    ).perform

    expect(result).to include(provider_count: 1, imported_count: 0, skipped_count: 1, not_returned_count: 0)
    conflicts = Integrations::Medelement::SyncConflict.where(last_sync_run_id: sync_run.id)
    expect(conflicts.where(conflict_type: 'invalid_specialist')).to exist
    expect(conflicts.where(conflict_type: 'specialist_not_returned')).not_to exist
  end

  it 'treats a blank specialist code as a local unlinked resource' do
    account.enable_features!('scheduling')
    hook = create(:integrations_hook, :medelement, account: account)
    sync_run = Integrations::Medelement::SyncRun.create!(account: account, hook: hook)
    create(
      :scheduling_resource,
      account: account,
      custom_attributes: { 'medelement_specialist_code' => '' }
    )

    result = described_class.new(
      account: account,
      client: client,
      configuration: configuration,
      conflict_tracker: Integrations::Medelement::ConflictTracker.new(sync_run: sync_run)
    ).perform

    expect(result).to include(local_unlinked_count: 1, not_returned_count: 0)
    expect(
      Integrations::Medelement::SyncConflict.where(
        last_sync_run_id: sync_run.id,
        conflict_type: 'specialist_not_returned'
      )
    ).not_to exist
  end

  it 'rejects an empty injected snapshot without recording every linked specialist as missing' do
    account.enable_features!('scheduling')
    hook = create(:integrations_hook, :medelement, account: account)
    sync_run = Integrations::Medelement::SyncRun.create!(account: account, hook: hook)
    existing_resource = create(
      :scheduling_resource,
      account: account,
      custom_attributes: { 'medelement_specialist_code' => 'existing-specialist' }
    )

    expect do
      described_class.new(
        account: account,
        client: nil,
        configuration: configuration,
        source: { specialists: [], cabinets: [] },
        conflict_tracker: Integrations::Medelement::ConflictTracker.new(sync_run: sync_run)
      ).perform
    end.to raise_error(
      Integrations::Medelement::SpecialistsSnapshotService::IncompleteSnapshotError,
      'Medelement specialists snapshot is empty'
    )

    expect(existing_resource.reload).to be_active
    expect(Integrations::Medelement::SyncConflict.where(last_sync_run_id: sync_run.id)).to be_empty
  end

  it 'rejects an unstable live snapshot before applying any database changes' do
    existing_resource = create(
      :scheduling_resource,
      account: account,
      custom_attributes: {
        'medelement_specialist_code' => 'missing-from-partial-response',
        'medelement_last_seen_at' => 8.days.ago.iso8601
      }
    )
    stable_first_read = [
      {
        'specialistCode' => 'ME-SPEC-001',
        'userName' => 'Synthetic specialist'
      }
    ]
    allow(client).to receive(:specialists).and_return(stable_first_read, [])

    expect do
      described_class.new(account: account, client: client, configuration: configuration).perform
    end.to raise_error(
      Integrations::Medelement::SpecialistsSnapshotService::IncompleteSnapshotError,
      'Medelement specialists snapshot is empty'
    ).and not_change(account.scheduling_resources, :count)

    expect(existing_resource.reload).to be_active
  end

  it 'does not deactivate a stale specialist when a stable live snapshot may be truncated' do
    existing_resource = create(
      :scheduling_resource,
      account: account,
      custom_attributes: {
        'medelement_specialist_code' => 'missing-from-stable-partial-response',
        'medelement_last_seen_at' => 8.days.ago.iso8601
      }
    )

    described_class.new(account: account, client: client, configuration: configuration).perform

    expect(existing_resource.reload).to be_active
    expect(client).to have_received(:specialists).twice
  end

  it 'does not recreate work rules after the default schedule has already been seeded once' do
    resource = create(
      :scheduling_resource,
      account: account,
      custom_attributes: {
        'medelement_specialist_code' => '27492901726817790',
        'medelement_default_work_rules_seeded_at' => 1.day.ago.iso8601
      }
    )
    create(:scheduling_work_rule, resource: resource, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)

    expect do
      described_class.new(account: account, client: client, configuration: configuration).perform
    end.not_to change(account.scheduling_work_rules, :count)
  end

  it 'keeps an intentionally empty schedule empty after a later specialist sync' do
    described_class.new(account: account, client: client, configuration: configuration).perform
    resource = account.scheduling_resources.last
    resource.work_rules.destroy_all

    described_class.new(account: account, client: client, configuration: configuration).perform

    expect(resource.reload.work_rules).to be_empty
    expect(resource.custom_attributes['medelement_default_work_rules_seeded_at']).to be_present
  end

  it 'records one invalid row and imports the remaining specialists' do
    allow(client).to receive(:specialists).and_return(
      [
        { 'specialistCode' => 'invalid-zone', 'userName' => 'Invalid', 'timezone' => 'Mars/Unknown' },
        { 'specialistCode' => 'valid-zone', 'userName' => 'Valid', 'timezone' => 'Asia/Almaty' }
      ]
    )
    tracker = instance_double(Integrations::Medelement::ConflictTracker, record!: true)

    result = described_class.new(account: account, client: client, configuration: configuration,
                                 conflict_tracker: tracker).perform

    expect(result).to include(provider_count: 2, imported_count: 1, skipped_count: 1)
    expect(account.scheduling_resources.pluck(:name)).to contain_exactly('Valid')
    expect(tracker).to have_received(:record!).with(
      hash_including(phase: 'specialists', entity_key: 'invalid-zone', conflict_type: 'invalid_specialist')
    )
  end

  it 'continues after a uniqueness error on one specialist row' do
    existing = create(:scheduling_resource, account: account,
                                            custom_attributes: { 'medelement_specialist_code' => 'duplicate-code' })
    allow(existing).to receive(:save!).and_raise(ActiveRecord::RecordNotUnique, 'synthetic conflict')
    allow(client).to receive(:specialists).and_return(
      [
        { 'specialistCode' => 'duplicate-code', 'userName' => 'Duplicate' },
        { 'specialistCode' => 'valid-code', 'userName' => 'Valid' }
      ]
    )
    tracker = instance_double(Integrations::Medelement::ConflictTracker, record!: true)
    sync = described_class.new(account: account, client: client, configuration: configuration,
                               conflict_tracker: tracker)
    allow(sync).to receive(:find_resource).and_call_original
    allow(sync).to receive(:find_resource).with('duplicate-code').and_return(existing)

    expect(sync.perform).to include(imported_count: 1, skipped_count: 1)
    expect(account.scheduling_resources.find_by("custom_attributes ->> 'medelement_specialist_code' = ?", 'valid-code')).to be_present
    expect(tracker).to have_received(:record!).with(hash_including(entity_key: 'duplicate-code', conflict_type: 'invalid_specialist'))
  end

  it 'replaces legacy 24/7 Medelement default rules with the new business schedule' do
    resource = create(
      :scheduling_resource,
      account: account,
      custom_attributes: {
        'medelement_specialist_code' => '27492901726817790',
        'medelement_default_work_rules_seeded_at' => 1.day.ago.iso8601
      }
    )

    (0..6).each do |weekday|
      create(
        :scheduling_work_rule,
        resource: resource,
        weekday: weekday,
        start_minute: 0,
        end_minute: 24 * 60,
        active: true
      )
    end

    described_class.new(account: account, client: client, configuration: configuration).perform

    expect(resource.reload.work_rules.order(:weekday).pluck(:weekday, :start_minute, :end_minute, :active)).to eq(expected_default_rules)
  end

  it 'imports the normalized specialist and cabinet contract without changing native resource ids' do
    existing_resource = create(
      :scheduling_resource,
      account: account,
      name: 'Old name',
      specialty: 'Manual specialty',
      custom_attributes: { 'medelement_specialist_code' => 'ME-SPEC-001' }
    )
    specialists = [
      {
        'specialistCode' => 'ME-SPEC-001',
        'fullName' => 'Imported specialist',
        'specialty' => 'Radiologist',
        'schedulePublished' => 1,
        'slotDurationMin' => 40,
        'cabinetCodes' => ['ME-CAB-001']
      }
    ]
    cabinets = [
      {
        'companyCabinetCode' => 'ME-CAB-001',
        'cabinetName' => 'MRI room',
        'cabinetNumber' => '101',
        'active' => true
      }
    ]

    described_class.new(
      account: account,
      client: nil,
      configuration: configuration,
      source: { specialists: specialists, cabinets: cabinets }
    ).perform

    resource = existing_resource.reload
    expect(resource).to have_attributes(
      id: existing_resource.id,
      name: 'Imported specialist',
      specialty: 'Radiologist',
      slot_duration_min: 40,
      active: true
    )
    expect(resource.custom_attributes['medelement_cabinets']).to contain_exactly(
      hash_including(
        'companyCabinetCode' => 'ME-CAB-001',
        'cabinetName' => 'MRI room'
      )
    )
  end

  it 'preserves a manual specialty when the provider sends no specialty' do
    resource = create(
      :scheduling_resource,
      account: account,
      specialty: 'Manual specialty',
      custom_attributes: { 'medelement_specialist_code' => '27492901726817790' }
    )

    described_class.new(account: account, client: client, configuration: configuration).perform

    expect(resource.reload.specialty).to eq('Manual specialty')
  end

  it 'deactivates only imported specialists missing beyond the grace period' do
    now = Time.zone.parse('2026-07-28 10:00:00')
    stale_resource = create(
      :scheduling_resource,
      account: account,
      custom_attributes: {
        'medelement_specialist_code' => 'missing-stale',
        'medelement_last_seen_at' => (now - 8.days).iso8601
      }
    )
    recent_resource = create(
      :scheduling_resource,
      account: account,
      custom_attributes: {
        'medelement_specialist_code' => 'missing-recent',
        'medelement_last_seen_at' => (now - 6.days).iso8601
      }
    )

    authoritative_source = { specialists: client.specialists, cabinets: [] }
    described_class.new(
      account: account,
      client: nil,
      configuration: configuration,
      source: authoritative_source,
      now: now
    ).perform

    expect(stale_resource.reload).not_to be_active
    expect(recent_resource.reload).to be_active
  end

  it 'records conflicting cabinet names and preserves the last accepted cabinet snapshot' do
    resource = create(
      :scheduling_resource,
      account: account,
      custom_attributes: {
        'medelement_specialist_code' => 'ME-SPEC-001',
        'medelement_cabinets' => [
          { 'companyCabinetCode' => 'ME-CAB-001', 'cabinetName' => 'Accepted room' }
        ]
      }
    )
    source = {
      specialists: [
        {
          'specialistCode' => 'ME-SPEC-001',
          'userName' => 'Imported specialist',
          'cabinetCodes' => ['ME-CAB-001']
        }
      ],
      cabinets: [
        { 'companyCabinetCode' => 'ME-CAB-001', 'cabinetName' => 'Room A' },
        { 'companyCabinetCode' => 'ME-CAB-001', 'cabinetName' => 'Room B' }
      ]
    }
    conflict_tracker = instance_double(Integrations::Medelement::ConflictTracker, record!: true)

    described_class.new(
      account: account,
      client: nil,
      configuration: configuration,
      source: source,
      conflict_tracker: conflict_tracker
    ).perform

    expect(resource.reload.custom_attributes['medelement_cabinets']).to contain_exactly(
      hash_including('companyCabinetCode' => 'ME-CAB-001', 'cabinetName' => 'Accepted room')
    )
    expect(conflict_tracker).to have_received(:record!).with(
      hash_including(
        phase: 'specialists',
        conflict_type: 'conflicting_cabinet_name',
        entity_key: 'ME-CAB-001',
        details: hash_including(cabinet_code: 'ME-CAB-001', variants_count: 2)
      )
    )
  end
end
