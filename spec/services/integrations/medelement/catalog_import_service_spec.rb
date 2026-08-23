require 'rails_helper'

RSpec.describe Integrations::Medelement::CatalogImportService do
  let(:account) { create(:account) }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }
  let(:configuration) { instance_double(Integrations::Medelement::Configuration, time_zone: 'Asia/Almaty') }
  let(:payload) do
    {
      'specialists' => [
        {
          'specialistCode' => 'ME-SPEC-001',
          'fullName' => 'Synthetic specialist',
          'specialty' => 'Radiologist',
          'schedulePublished' => 1,
          'slotDurationMin' => 30,
          'cabinetCodes' => ['ME-CAB-001'],
          'serviceCodes' => ['ME-SVC-001']
        }
      ],
      'cabinets' => [
        {
          'companyCabinetCode' => 'ME-CAB-001',
          'cabinetName' => 'MRI room',
          'cabinetNumber' => '101',
          'active' => true
        }
      ],
      'services' => [
        {
          'serviceCode' => 'ME-SVC-001',
          'name' => 'MRI',
          'durationMin' => 30,
          'basePrice' => 15_000,
          'category' => 'Diagnostics',
          'direction' => 'Radiology',
          'serviceType' => 'diagnostic',
          'active' => true
        }
      ],
      'specialistServices' => [
        {
          'specialistCode' => 'ME-SPEC-001',
          'serviceCode' => 'ME-SVC-001',
          'price' => 17_000,
          'compensationType' => 'percent',
          'compensationValue' => 20,
          'active' => true
        }
      ],
      'sectors' => [{ 'sectorCode' => 'IGNORED' }],
      'sectorLinks' => [{ 'sectorCode' => 'IGNORED', 'specialistCode' => 'ME-SPEC-001' }]
    }
  end

  before do
    account.enable_features!('scheduling')
    allow(Integrations::Medelement::Configuration).to receive(:new).with(hook: hook).and_return(configuration)
  end

  it 'imports all core package sections into the native scheduling contract and ignores sectors' do
    result = described_class.new(hook: hook, payload: payload).perform

    resource = account.scheduling_resources.find_by!("custom_attributes ->> 'medelement_specialist_code' = ?", 'ME-SPEC-001')
    service = account.scheduling_services.find_by!("custom_attributes ->> 'medelement_nomenclature_code' = ?", 'ME-SVC-001')
    service_price = service.prices.find_by!(resource: resource)

    expect(result).to eq(
      specialists: {
        provider_count: 1,
        imported_count: 1,
        skipped_count: 0,
        not_returned_count: 0,
        local_unlinked_count: 0
      },
      services: {
        provider_count: 1,
        imported_count: 1,
        linked_count: 1,
        skipped_count: 0,
        not_returned_count: 0,
        local_unlinked_count: 0
      }
    )
    expect(resource).to have_attributes(name: 'Synthetic specialist', specialty: 'Radiologist')
    expect(resource.custom_attributes['medelement_cabinets']).to contain_exactly(
      hash_including('companyCabinetCode' => 'ME-CAB-001', 'cabinetName' => 'MRI room')
    )
    expect(service).to have_attributes(name: 'MRI', duration_min: 30, base_price: 15_000)
    expect(service_price).to have_attributes(price: 17_000, compensation_type: 'percent', compensation_value: 20)
  end

  it 'rejects links to specialists or services outside the snapshot' do
    invalid_payload = payload.deep_dup
    invalid_payload['specialistServices'][0]['serviceCode'] = 'missing-service'

    expect do
      described_class.new(hook: hook, payload: invalid_payload).perform
    end.to raise_error(
      Integrations::Medelement::CatalogImportService::InvalidPayloadError,
      'specialistServices references an unknown specialist or service'
    )

    expect(account.scheduling_resources).to be_empty
    expect(account.scheduling_services.count).to be_zero
  end

  it 'imports free services and specialist links with a zero price' do
    free_payload = payload.deep_dup
    free_payload['services'][0]['basePrice'] = 0
    free_payload['specialistServices'][0]['price'] = 0

    result = described_class.new(hook: hook, payload: free_payload).perform

    expect(result.dig(:services, :skipped_count)).to be_zero
    expect(account.scheduling_services.first).to have_attributes(base_price: 0)
    expect(account.scheduling_services.first.prices.first).to have_attributes(price: 0, active: true)
  end

  it 'rolls back the entire catalog when a link has a negative price' do
    invalid_payload = payload.deep_dup
    invalid_payload['specialistServices'][0]['price'] = -1

    expect do
      described_class.new(hook: hook, payload: invalid_payload).perform
    end.to raise_error(
      Integrations::Medelement::CatalogImportService::InvalidPayloadError,
      'Not all catalog rows could be imported'
    )

    expect(Scheduling::Resource.where(account: account)).to be_empty
    expect(Scheduling::Service.where(account: account)).to be_empty
    expect(Scheduling::ServicePrice.where(account: account)).to be_empty
  end
end
