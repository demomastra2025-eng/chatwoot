require 'rails_helper'

RSpec.describe Integrations::Medelement::ServicesSyncService do
  let(:account) { create(:account) }
  let(:client) { instance_double(Integrations::Medelement::Client) }
  let(:normalized_service_payloads) do
    [
      {
        'serviceCode' => 'ME-SVC-001',
        'name' => 'MRI',
        'durationMin' => 40,
        'basePrice' => 15_000,
        'category' => 'Diagnostics',
        'direction' => 'Radiology',
        'serviceType' => 'diagnostic',
        'active' => true
      }
    ]
  end
  let(:normalized_specialist_service_payloads) do
    [
      {
        'specialistCode' => 'ME-SPEC-001',
        'serviceCode' => 'ME-SVC-001',
        'price' => 17_000,
        'compensationType' => 'percent',
        'compensationValue' => 25,
        'active' => true
      }
    ]
  end

  it 'loads the complete paginated live catalog and imports only leaf services' do
    allow(client).to receive(:nomenclatures).with(skip: 0).and_return(
      [
        {
          'NOMENCLATURE_CODE' => 'ME-SVC-001',
          'NOMENCLATURE_NAME' => 'MRI',
          'PRICE' => 15_000.0,
          'IS_GROUP' => 0,
          'PARENT_CODE' => 'ME-GROUP-001',
          'PARENT_NAME' => 'Diagnostics',
          'NOMENCLATURE_TYPE_CODE' => 4,
          'UNIT_NAME' => 'service',
          'RECCOUNT' => 2
        }
      ]
    )
    allow(client).to receive(:nomenclatures).with(skip: 1).and_return(
      [
        {
          'NOMENCLATURE_CODE' => 'ME-GROUP-001',
          'NOMENCLATURE_NAME' => 'Diagnostics',
          'IS_GROUP' => 1,
          'RECCOUNT' => 2
        }
      ]
    )

    result = described_class.new(account: account, client: client).perform

    expect(result).to include(imported_count: 1, linked_count: 0, skipped_count: 0)
    expect(client).to have_received(:nomenclatures).with(skip: 0).once
    expect(client).to have_received(:nomenclatures).with(skip: 1).once
    expect(account.scheduling_services.count).to eq(1)

    service = account.scheduling_services.first
    expect(service).to have_attributes(
      name: 'MRI',
      base_price: 15_000,
      duration_min: 30,
      category: 'Diagnostics',
      service_type: '4',
      active: true
    )
    expect(service.custom_attributes).to include(
      'medelement_nomenclature_code' => 'ME-SVC-001',
      'medelement_parent_code' => 'ME-GROUP-001',
      'medelement_unit_name' => 'service'
    )
  end

  it 'upserts normalized services and specialist prices without changing native ids' do
    resource = create(
      :scheduling_resource,
      account: account,
      custom_attributes: { 'medelement_specialist_code' => 'ME-SPEC-001' }
    )
    sync = lambda do
      described_class.new(
        account: account,
        client: nil,
        service_payloads: normalized_service_payloads,
        specialist_service_payloads: normalized_specialist_service_payloads
      ).perform
    end

    first_result = sync.call
    service = account.scheduling_services.find_by!("custom_attributes ->> 'medelement_nomenclature_code' = ?", 'ME-SVC-001')
    service_price = service.prices.find_by!(resource: resource)
    original_ids = [service.id, service_price.id]

    second_result = sync.call

    expect(first_result).to include(imported_count: 1, linked_count: 1, skipped_count: 0)
    expect(second_result).to include(imported_count: 1, linked_count: 1, skipped_count: 0)
    expect([service.reload.id, service_price.reload.id]).to eq(original_ids)
    expect(service).to have_attributes(
      duration_min: 40,
      base_price: 15_000,
      category: 'Diagnostics',
      direction: 'Radiology',
      service_type: 'diagnostic'
    )
    expect(service_price).to have_attributes(
      price: 17_000,
      compensation_type: 'percent',
      compensation_value: 25,
      active: true
    )
  end

  it 'keeps a provider name that exceeds the native display-name limit' do
    provider_name = 'Long provider service ' * 20

    result = described_class.new(
      account: account,
      client: nil,
      service_payloads: [
        {
          'NOMENCLATURE_CODE' => 'ME-SVC-LONG',
          'NOMENCLATURE_NAME' => provider_name,
          'PRICE' => 1000,
          'IS_GROUP' => 0
        }
      ]
    ).perform

    service = account.scheduling_services.find_by!(
      "custom_attributes ->> 'medelement_nomenclature_code' = ?", 'ME-SVC-LONG'
    )
    expect(result).to include(imported_count: 1, linked_count: 0, skipped_count: 0)
    expect(service.name.length).to eq(255)
    expect(service.custom_attributes['medelement_full_name']).to eq(provider_name)

    described_class.new(
      account: account,
      client: nil,
      service_payloads: [
        {
          'NOMENCLATURE_CODE' => 'ME-SVC-LONG',
          'NOMENCLATURE_NAME' => 'Short provider service',
          'PRICE' => 1000,
          'IS_GROUP' => 0
        }
      ]
    ).perform

    expect(service.reload.name).to eq('Short provider service')
    expect(service.custom_attributes).not_to have_key('medelement_full_name')
  end

  it 'reports local-only services and does not mark a malformed returned code as missing' do
    create(:scheduling_service, account: account)
    create(:scheduling_service, account: account, custom_attributes: { 'medelement_nomenclature_code' => '' })
    create(
      :scheduling_service,
      account: account,
      custom_attributes: { 'medelement_nomenclature_code' => 'ME-SVC-MALFORMED' }
    )

    result = described_class.new(
      account: account,
      client: nil,
      service_payloads: [{ 'NOMENCLATURE_CODE' => 'ME-SVC-MALFORMED', 'NOMENCLATURE_NAME' => '' }]
    ).perform

    expect(result).to include(
      provider_count: 1,
      imported_count: 0,
      skipped_count: 1,
      not_returned_count: 0,
      local_unlinked_count: 2
    )
  end

  it 'records an active linked service that is absent from the provider snapshot' do
    now = Time.zone.parse('2026-07-28 10:00:00')
    create(
      :scheduling_service,
      account: account,
      custom_attributes: {
        'medelement_nomenclature_code' => 'ME-SVC-MISSING',
        'medelement_last_seen_at' => now.iso8601
      }
    )
    conflict_tracker = instance_double(Integrations::Medelement::ConflictTracker, record!: true)

    result = described_class.new(
      account: account,
      client: nil,
      conflict_tracker: conflict_tracker,
      now: now,
      service_payloads: normalized_service_payloads
    ).perform

    expect(result).to include(provider_count: 1, imported_count: 1, not_returned_count: 1)
    expect(conflict_tracker).to have_received(:record!).with(
      hash_including(phase: 'services', conflict_type: 'service_not_returned', severity: 'warning')
    )
  end

  it 'rejects an empty injected snapshot without reporting every imported service as missing' do
    now = Time.zone.parse('2026-07-28 10:00:00')
    service = create(
      :scheduling_service,
      account: account,
      custom_attributes: {
        'medelement_nomenclature_code' => 'ME-SVC-OLD',
        'medelement_last_seen_at' => (now - 8.days).iso8601
      }
    )
    service_price = create(:scheduling_service_price, account: account, service: service)

    expect do
      described_class.new(account: account, client: nil, service_payloads: [], now: now).perform
    end.to raise_error(
      described_class::IncompleteSnapshotError,
      'Medelement services snapshot has no services'
    )

    expect(service.reload).to be_active
    expect(service_price.reload).to be_active
  end

  it 'keeps complete uncounted pages when the terminal page is empty' do
    page = Array.new(20) do |index|
      {
        'NOMENCLATURE_CODE' => "ME-SVC-#{index}",
        'NOMENCLATURE_NAME' => "Service #{index}",
        'IS_GROUP' => 0
      }
    end
    allow(client).to receive(:nomenclatures).with(skip: 0).and_return(page)
    allow(client).to receive(:nomenclatures).with(skip: 20).and_return([])

    result = described_class.new(account: account, client: client).perform

    expect(result).to include(imported_count: 20, skipped_count: 0)
  end

  it 'rejects an incomplete live snapshot before applying any database changes' do
    allow(client).to receive(:nomenclatures).with(skip: 0).and_return(
      [
        {
          'NOMENCLATURE_CODE' => 'ME-SVC-001',
          'NOMENCLATURE_NAME' => 'MRI',
          'IS_GROUP' => 0,
          'RECCOUNT' => 2
        }
      ]
    )
    allow(client).to receive(:nomenclatures).with(skip: 1).and_return([])

    expect do
      described_class.new(account: account, client: client).perform
    end.to raise_error(described_class::IncompleteSnapshotError)
      .and not_change(account.scheduling_services, :count)
  end

  it 'rejects an empty first live page instead of deactivating existing services' do
    now = Time.zone.parse('2026-07-28 10:00:00')
    service = create(
      :scheduling_service,
      account: account,
      custom_attributes: {
        'medelement_nomenclature_code' => 'ME-SVC-OLD',
        'medelement_last_seen_at' => (now - 8.days).iso8601
      }
    )
    allow(client).to receive(:nomenclatures).with(skip: 0).and_return([])

    expect do
      described_class.new(account: account, client: client, now: now).perform
    end.to raise_error(described_class::IncompleteSnapshotError)

    expect(service.reload).to be_active
  end
end
