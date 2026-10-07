require 'rails_helper'

RSpec.describe Integrations::Medelement::ReceptionsDeltaService do
  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }
  let(:client) { instance_double(Integrations::Medelement::Client) }
  let(:importer) { instance_double(Integrations::Medelement::ReceptionsSyncService, import_reported_reception!: true) }
  let(:service) { described_class.new(hook: hook, client: client) }

  before do
    hook.update!(settings: hook.settings.merge('incremental_receptions_enabled' => true))
    allow(Integrations::Medelement::ReceptionsSyncService).to receive(:new).and_return(importer)
    allow(client).to receive(:get_reception) do |reception_code:, **|
      detail_for(reception_code)
    end
  end

  def detail_for(code)
    {
      'RECEPTION_CODE' => code, 'PROFILE_CODE' => 'patient-1', 'COMPANY_CODE' => '412849431501753534',
      'SPECIALIST_CODE' => 'doctor-1', 'COMPANY_CABINET_CODE' => 'cabinet-1',
      'STARTTIME' => '2026-10-07 10:00:00', 'ENDTIME' => '2026-10-07 10:20:00',
      'SERVICES' => [], 'REMOVED' => 0
    }
  end

  it 'fetches full details and advances the durable cursor only after applying every code' do
    allow(client).to receive(:receptions_by_update_date).and_return([{ 'receptionCode' => 'reception-1' }])

    result = service.perform

    cursor = Integrations::Medelement::SyncCursor.find_by!(hook: hook, name: 'receptions_delta')
    expect(result).to include(changed_codes: 1, applied: 1, complete: true)
    expect(cursor.value).to be_present
    expect(client).to have_received(:get_reception).with(reception_code: 'reception-1', version: :v2)
    expect(importer).to have_received(:import_reported_reception!).with(hash_including('RECEPTION_CODE' => 'reception-1'))
  end

  it 'retains the cursor when applying a detail fails' do
    allow(client).to receive(:receptions_by_update_date).and_return([{ 'RECEPTION_CODE' => 'reception-1' }])
    allow(importer).to receive(:import_reported_reception!).and_raise(StandardError, 'apply failed')

    expect { service.perform }.to raise_error(StandardError, 'apply failed')
    expect(Integrations::Medelement::SyncCursor.find_by!(hook: hook, name: 'receptions_delta').value).to be_nil
    expect(Integrations::Medelement::DeltaSeenReception.where(hook: hook)).to be_empty
  end

  it 'skips duplicates in the three-minute overlap without importing twice' do
    allow(client).to receive(:receptions_by_update_date).and_return([{ 'RECEPTION_CODE' => 'reception-1' }])

    service.perform
    result = service.perform

    expect(result).to include(applied: 0, skipped: 1)
    expect(importer).to have_received(:import_reported_reception!).once
    expect(Integrations::Medelement::DeltaSeenReception.where(hook: hook).count).to eq(1)
  end

  it 'carries codes beyond the cap into the next poll without moving the cursor early' do
    entries = (1..201).map { |number| { 'RECEPTION_CODE' => format('reception-%03d', number) } }
    allow(client).to receive(:receptions_by_update_date).and_return(entries)

    first = service.perform
    expect(first).to include(applied: 200, complete: false)
    expect(Integrations::Medelement::SyncCursor.find_by!(hook: hook, name: 'receptions_delta').value).to be_nil

    second = service.perform
    expect(second).to include(applied: 1, skipped: 200, complete: true)
    expect(Integrations::Medelement::SyncCursor.find_by!(hook: hook, name: 'receptions_delta').value).to be_present
    expect(importer).to have_received(:import_reported_reception!).exactly(201).times
  end

  it 'marks an out-of-scope reception as observed without blocking other codes' do
    allow(client).to receive(:receptions_by_update_date).and_return([{ 'RECEPTION_CODE' => 'reception-1' }])
    allow(importer).to receive(:import_reported_reception!).and_raise(
      Integrations::Medelement::ReceptionsSyncService::OutOfScopeReception
    )

    expect(service.perform).to include(applied: 0, skipped: 1, complete: true)
    expect(Integrations::Medelement::DeltaSeenReception.where(hook: hook).count).to eq(1)
  end

  it 'does not call MedElement or reconcile absences when the flag is off' do
    hook.update!(settings: hook.settings.merge('incremental_receptions_enabled' => false))

    expect(service.perform).to eq(:disabled)
    expect(client).not_to have_received(:get_reception)
    expect(Integrations::Medelement::MissingAppointmentReconciler).not_to receive(:new)
  end
end
