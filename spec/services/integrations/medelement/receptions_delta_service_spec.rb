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

  it 'does not import a fetched reception after the hook is disabled during the provider read' do
    allow(client).to receive(:receptions_by_update_date).and_return([{ 'RECEPTION_CODE' => 'reception-1' }])
    allow(client).to receive(:get_reception) do
      Integrations::Hook.find(hook.id).update!(status: 'disabled')
      detail_for('reception-1')
    end

    expect { service.perform }.to raise_error(described_class::IntegrationChangedError)
    expect(importer).not_to have_received(:import_reported_reception!)
    expect(Integrations::Medelement::SyncCursor.find_by!(hook: hook, name: 'receptions_delta').last_success_at).to be_nil
  end

  it 'does not import a detail fetched under settings that changed while reading the provider' do
    allow(client).to receive(:receptions_by_update_date).and_return([{ 'RECEPTION_CODE' => 'reception-1' }])
    allow(client).to receive(:get_reception) do
      record = Integrations::Hook.find(hook.id)
      record.update!(settings: record.settings.merge('sync_receptions' => false))
      detail_for('reception-1')
    end

    expect { service.perform }.to raise_error(described_class::IntegrationChangedError)
    expect(importer).not_to have_received(:import_reported_reception!)
  end

  it 'fetches full details and advances the durable cursor only after applying every code' do
    allow(client).to receive(:receptions_by_update_date).and_return([{ 'receptionCode' => 'reception-1' }])

    result = service.perform

    cursor = Integrations::Medelement::SyncCursor.find_by!(hook: hook, name: 'receptions_delta')
    expect(result).to include(changed_codes: 1, applied: 1, complete: true)
    expect(cursor.value).to be_present
    expect(client).to have_received(:get_reception).with(reception_code: 'reception-1', version: :v2)
    expect(importer).to have_received(:import_reported_reception!)
      .with(hash_including('RECEPTION_CODE' => 'reception-1'), entry_cabinet_code: nil,
                                                               snapshot_version: { exists: false, updated_at: nil })
  end

  describe 'an integration that changes before the poll can finish' do
    let!(:cursor) do
      Integrations::Medelement::SyncCursor.create!(
        hook: hook, name: 'receptions_delta', value: 10.minutes.ago, last_success_at: 10.minutes.ago
      )
    end

    it 'keeps the old watermark when an empty response arrives after disable' do
      original = cursor.attributes.slice('value', 'last_success_at')
      allow(client).to receive(:receptions_by_update_date) do
        Integrations::Hook.find(hook.id).update!(status: 'disabled')
        []
      end

      expect { service.perform }.to raise_error(described_class::IntegrationChangedError)
      expect(cursor.reload.attributes.slice('value', 'last_success_at')).to eq(original)
    end

    it 'keeps the old watermark when settings change during an empty response' do
      original = cursor.attributes.slice('value', 'last_success_at')
      allow(client).to receive(:receptions_by_update_date) do
        record = Integrations::Hook.find(hook.id)
        record.update!(settings: record.settings.merge('sync_receptions' => false))
        []
      end

      expect { service.perform }.to raise_error(described_class::IntegrationChangedError)
      expect(cursor.reload.attributes.slice('value', 'last_success_at')).to eq(original)
    end

    it 'also fences a poll that skips every already seen detail' do
      original = cursor.attributes.slice('value', 'last_success_at')
      Integrations::Medelement::DeltaSeenReception.create!(
        hook: hook, reception_code: 'reception-1',
        change_marker: Integrations::Medelement::ReceptionChangeMarker.call(detail_for('reception-1')),
        processed_at: Time.current
      )
      allow(client).to receive(:receptions_by_update_date).and_return([{ 'RECEPTION_CODE' => 'reception-1' }])
      allow(client).to receive(:get_reception) do
        Integrations::Hook.find(hook.id).update!(status: 'disabled')
        detail_for('reception-1')
      end

      expect { service.perform }.to raise_error(described_class::IntegrationChangedError)
      expect(cursor.reload.attributes.slice('value', 'last_success_at')).to eq(original)
      expect(importer).not_to have_received(:import_reported_reception!)
    end
  end

  describe 'a newer full snapshot committed while the delta detail was in flight' do
    let!(:resource) do
      create(:scheduling_resource, account: account, timezone: 'Asia/Almaty',
                                   custom_attributes: { 'medelement_specialist_code' => 'doctor-1',
                                                        'medelement_cabinets' => [{ 'company_cabinet_code' => 'cabinet-1' }] })
    end
    let(:date) { Time.current.in_time_zone('Asia/Almaty').strftime('%Y-%m-%d') }
    let(:old_detail) { detail_for('reception-1').merge('STARTTIME' => "#{date} 10:00:00", 'ENDTIME' => "#{date} 10:20:00", 'ACTIVE' => 1) }
    let(:new_detail) { old_detail.merge('PATIENT_CODE' => 'patient-1', 'STARTTIME' => "#{date} 12:00:00", 'ENDTIME' => "#{date} 12:20:00") }
    let(:full_client) { instance_double(Integrations::Medelement::Client) }

    before do
      hook.update!(settings: hook.settings.merge('sync_patients' => false))
      allow(Integrations::Medelement::ReceptionsSyncService).to receive(:new).and_call_original
      allow(full_client).to receive(:get_receptions).and_return([new_detail])
      allow(full_client).to receive(:get_reception).and_return(new_detail)
      allow(client).to receive(:receptions_by_update_date).and_return([{ 'RECEPTION_CODE' => 'reception-1' }])
      allow(client).to receive(:get_reception) do
        Integrations::Medelement::ReceptionsSyncService.new(
          account: account, client: full_client, configuration: Integrations::Medelement::Configuration.new(hook: hook)
        ).perform
        old_detail
      end
    end

    def expect_newer_snapshot_to_survive
      expect(service.perform).to include(applied: 0, skipped: 1, complete: true)
      appointments = account.scheduling_appointments.where(external_ref: 'medelement:reception:reception-1')
      expect(appointments.count).to eq(1)
      expect(appointments.first.starts_at.in_time_zone('Asia/Almaty').strftime('%H:%M')).to eq('12:00')
    end

    it 'does not overwrite an existing appointment with the older detail' do
      create(:scheduling_appointment, account: account, resource: resource, source: 'medelement',
                                      external_ref: 'medelement:reception:reception-1',
                                      starts_at: Time.zone.parse("#{date} 10:00:00"), ends_at: Time.zone.parse("#{date} 10:20:00"))
      expect_newer_snapshot_to_survive
    end

    it 'does not overwrite an appointment that the full snapshot created during the read' do
      expect_newer_snapshot_to_survive
    end

    it 'does not cancel the newer appointment from an older removal detail' do
      create(:scheduling_appointment, account: account, resource: resource, source: 'medelement',
                                      external_ref: 'medelement:reception:reception-1',
                                      starts_at: Time.zone.parse("#{date} 10:00:00"), ends_at: Time.zone.parse("#{date} 10:20:00"))
      allow(client).to receive(:get_reception) do
        Integrations::Medelement::ReceptionsSyncService.new(
          account: account, client: full_client, configuration: Integrations::Medelement::Configuration.new(hook: hook)
        ).perform
        old_detail.merge('REMOVED' => 1)
      end
      expect_newer_snapshot_to_survive
      expect(account.scheduling_appointments.find_by!(external_ref: 'medelement:reception:reception-1').status).not_to eq('cancelled')
    end
  end

  describe 'the cabinet of the update list' do
    def import_with_entries(entries)
      allow(client).to receive(:receptions_by_update_date).and_return(entries)
      service.perform
    end

    it 'passes the cabinet the entry of the code reports, in any of its spellings' do
      import_with_entries(
        [{ 'RECEPTION_CODE' => 'reception-1', 'COMPANY_CABINET_CODE' => 'cabinet-2' },
         { 'receptionCode' => 'reception-2', 'companyCabinetCode' => 'cabinet-3' }]
      )

      expect(importer).to have_received(:import_reported_reception!)
        .with(hash_including('RECEPTION_CODE' => 'reception-1'), entry_cabinet_code: 'cabinet-2',
                                                                 snapshot_version: { exists: false, updated_at: nil })
      expect(importer).to have_received(:import_reported_reception!)
        .with(hash_including('RECEPTION_CODE' => 'reception-2'), entry_cabinet_code: 'cabinet-3',
                                                                 snapshot_version: { exists: false, updated_at: nil })
    end

    it 'passes the cabinet that several entries of one code agree on, and none when they disagree or give none' do
      import_with_entries(
        [{ 'RECEPTION_CODE' => 'reception-1', 'COMPANY_CABINET_CODE' => 'cabinet-2' },
         { 'RECEPTION_CODE' => 'reception-1' },
         { 'RECEPTION_CODE' => 'reception-1', 'COMPANY_CABINET_CODE' => 'cabinet-2' },
         { 'RECEPTION_CODE' => 'reception-2', 'COMPANY_CABINET_CODE' => 'cabinet-2' },
         { 'RECEPTION_CODE' => 'reception-2', 'COMPANY_CABINET_CODE' => 'cabinet-3' },
         { 'RECEPTION_CODE' => 'reception-3', 'COMPANY_CABINET_CODE' => '' }]
      )

      expect(importer).to have_received(:import_reported_reception!)
        .with(hash_including('RECEPTION_CODE' => 'reception-1'), entry_cabinet_code: 'cabinet-2',
                                                                 snapshot_version: { exists: false, updated_at: nil })
      expect(importer).to have_received(:import_reported_reception!)
        .with(hash_including('RECEPTION_CODE' => 'reception-2'), entry_cabinet_code: nil,
                                                                 snapshot_version: { exists: false, updated_at: nil })
      expect(importer).to have_received(:import_reported_reception!)
        .with(hash_including('RECEPTION_CODE' => 'reception-3'), entry_cabinet_code: nil,
                                                                 snapshot_version: { exists: false, updated_at: nil })
    end

    it 'imports a reception of a multi-cabinet specialist with the cabinet of its entry, through the real import' do
      create(:scheduling_resource, account: account, timezone: 'Asia/Almaty',
                                   custom_attributes: { 'medelement_specialist_code' => 'doctor-1',
                                                        'medelement_cabinets' => [{ 'company_cabinet_code' => 'cabinet-1' },
                                                                                  { 'company_cabinet_code' => 'cabinet-2' }] })
      hook.update!(settings: hook.settings.merge('sync_patients' => false))
      allow(Integrations::Medelement::ReceptionsSyncService).to receive(:new).and_call_original
      allow(client).to receive(:get_reception) { |reception_code:, **| detail_for(reception_code).except('COMPANY_CABINET_CODE') }

      import_with_entries([{ 'RECEPTION_CODE' => 'reception-1' }, { 'RECEPTION_CODE' => 'reception-2', 'COMPANY_CABINET_CODE' => 'cabinet-2' }])

      expect(Scheduling::Appointment.find_by(external_ref: 'medelement:reception:reception-1')).to be_nil
      expect(Scheduling::Appointment.find_by!(external_ref: 'medelement:reception:reception-2').custom_attributes)
        .to include('medelement_cabinet_code' => 'cabinet-2')
    end
  end

  it 'retains the cursor when applying a detail fails' do
    allow(client).to receive(:receptions_by_update_date).and_return([{ 'RECEPTION_CODE' => 'reception-1' }])
    allow(importer).to receive(:import_reported_reception!).and_raise(StandardError, 'apply failed')

    expect { service.perform }.to raise_error(StandardError, 'apply failed')
    cursor = Integrations::Medelement::SyncCursor.find_by!(hook: hook, name: 'receptions_delta')
    expect(cursor.value).to be_present
    expect(cursor.last_success_at).to be_nil
    expect(Integrations::Medelement::DeltaSeenReception.where(hook: hook)).to be_empty
  end

  it 'skips duplicates in the three-minute overlap without importing twice' do
    allow(client).to receive(:receptions_by_update_date).and_return([{ 'RECEPTION_CODE' => 'reception-1' }])

    service.perform
    result = service.perform

    expect(result).to include(applied: 0, skipped: 1)
    expect(importer).to have_received(:import_reported_reception!).once
    expect(client).to have_received(:get_reception).twice
    expect(Integrations::Medelement::DeltaSeenReception.where(hook: hook).count).to eq(1)
  end

  it 'keeps the first lower bound across a slow capped poll and advances only after draining' do
    entries = (1..201).map { |number| { 'RECEPTION_CODE' => format('reception-%03d', number) } }
    started_at = Time.current.change(sec: 0)
    lower_bound = (started_at - 3.minutes).in_time_zone(
      Integrations::Medelement::Configuration.new(hook: hook).time_zone
    ).strftime('%d.%m.%Y %H:%M')
    requests = []
    allow(client).to receive(:receptions_by_update_date) do |update_date_from:|
      requests << update_date_from
      travel 4.minutes if requests.one?
      update_date_from == lower_bound ? entries : []
    end

    travel_to(started_at) do
      first = service.perform
      cursor = Integrations::Medelement::SyncCursor.find_by!(hook: hook, name: 'receptions_delta')
      expect(first).to include(applied: 200, complete: false)
      expect(cursor.value).to eq(started_at - 3.minutes)
      expect(cursor.last_success_at).to be_nil

      second = service.perform
      expect(second).to include(applied: 1, skipped: 200, complete: true)
      expect(cursor.reload.value).to eq(started_at + 4.minutes)
      expect(requests).to eq([lower_bound, lower_bound])
      expect(importer).to have_received(:import_reported_reception!).exactly(201).times
    end
  end

  it 'skips details when the update list contains a complete marker already seen' do
    entry = detail_for('reception-1')
    (Integrations::Medelement::ReceptionChangeMarker::FIELDS - entry.keys).each { |field| entry[field] = nil }
    allow(client).to receive(:receptions_by_update_date).and_return([entry])
    allow(client).to receive(:get_reception).and_return(entry)

    expect(service.perform).to include(applied: 1, complete: true)
    expect(service.perform).to include(applied: 0, skipped: 1, complete: true)
    expect(client).to have_received(:get_reception).once
  end

  it 'keeps the first lower bound after a rate-limited update list request' do
    started_at = Time.current.change(sec: 0)
    requests = []
    allow(client).to receive(:receptions_by_update_date) do |update_date_from:|
      requests << update_date_from
      raise Integrations::Medelement::Client::ApiError.new('rate limited', status: 429) if requests.one?

      []
    end

    travel_to(started_at) do
      expect { service.perform }.to raise_error(Integrations::Medelement::Client::ApiError)
      cursor = Integrations::Medelement::SyncCursor.find_by!(hook: hook, name: 'receptions_delta')
      expect(cursor.value).to eq(started_at - 3.minutes)
      expect(cursor.last_success_at).to be_nil

      travel 6.minutes
      expect(service.perform).to include(complete: true)
      expect(requests.size).to eq(2)
      expect(requests.uniq.size).to eq(1)
    end
  end

  it 'marks an out-of-scope reception as observed without blocking other codes' do
    allow(client).to receive(:receptions_by_update_date).and_return([{ 'RECEPTION_CODE' => 'reception-1' }])
    allow(importer).to receive(:import_reported_reception!).and_raise(
      Integrations::Medelement::ReceptionsSyncService::OutOfScopeReception
    )

    expect(service.perform).to include(applied: 0, skipped: 1, complete: true)
    expect(Integrations::Medelement::DeltaSeenReception.where(hook: hook).count).to eq(1)
  end

  describe 'a reception the importer refuses' do
    let(:refusals) do
      {
        'StaleSnapshotError' => Integrations::Medelement::AppointmentSnapshotGuard::StaleSnapshotError.new('newer local change'),
        'InvalidReceptionError' => Integrations::Medelement::ReceptionsSyncService::InvalidReceptionError.new('missing end time'),
        'InvalidSnapshotError' => Integrations::Medelement::ReceptionServiceRows::InvalidSnapshotError.new('not a row'),
        'RecordInvalid' => ActiveRecord::RecordInvalid.new(Scheduling::Appointment.new),
        'Error' => Scheduling::Error.new(code: 'DUPLICATE_EXTERNAL_REF', message: 'external_ref is taken', status: :conflict)
      }
    end

    def refuse(code, error)
      allow(importer).to receive(:import_reported_reception!) do |detail, **|
        raise error if detail['RECEPTION_CODE'] == code

        true
      end
    end

    it 'is skipped, logged and marked as handled, and the poll goes on with the next reception' do
      refusals.each_with_index do |(name, error), index|
        allow(client).to receive(:receptions_by_update_date).and_return(
          [{ 'RECEPTION_CODE' => "bad-#{index}" }, { 'RECEPTION_CODE' => "good-#{index}" }]
        )
        refuse("bad-#{index}", error)
        lines = []
        allow(Rails.logger).to receive(:warn) { |line| lines << line }

        result = service.perform

        expect(result).to include(changed_codes: 2, applied: 1, skipped: 1, complete: true), name
        expect(lines.grep(/MEDELEMENT::DELTA/)).to contain_exactly(a_string_matching(/\[MEDELEMENT::DELTA\] Skipping reception.*reason=\S*#{name}\z/))
        seen = Integrations::Medelement::DeltaSeenReception.where(hook: hook, reception_code: ["bad-#{index}", "good-#{index}"])
        expect(seen.count).to eq(2)
      end
    end

    it 'does not stall the poll: the cursor advances, and the reception is not read again until MedElement changes it' do
      allow(client).to receive(:receptions_by_update_date).and_return([{ 'RECEPTION_CODE' => 'bad-1' }, { 'RECEPTION_CODE' => 'good-1' }])
      refuse('bad-1', Scheduling::Error.new(code: 'DUPLICATE_EXTERNAL_REF', message: 'external_ref is taken', status: :conflict))

      first = service.perform
      second = service.perform

      cursor = Integrations::Medelement::SyncCursor.find_by!(hook: hook, name: 'receptions_delta')
      expect(first).to include(applied: 1, skipped: 1, complete: true)
      expect(second).to include(applied: 0, skipped: 2, complete: true)
      expect(cursor.last_success_at).to be_present
      expect(importer).to have_received(:import_reported_reception!).twice
    end

    it 'reads it again when MedElement changes the reception, which is a new change marker' do
      allow(client).to receive(:receptions_by_update_date).and_return([{ 'RECEPTION_CODE' => 'bad-1' }])
      refuse('bad-1', Integrations::Medelement::ReceptionsSyncService::InvalidReceptionError.new('missing end time'))
      service.perform

      allow(client).to receive(:get_reception) { |reception_code:, **| detail_for(reception_code).merge('ENDTIME' => '2026-10-07 10:40:00') }
      result = service.perform

      expect(result).to include(applied: 0, skipped: 1, complete: true)
      expect(importer).to have_received(:import_reported_reception!).twice
    end

    it 'logs no reception code or message: only a digest of the code and the class of the refusal' do
      allow(client).to receive(:receptions_by_update_date).and_return([{ 'RECEPTION_CODE' => 'bad-1' }])
      refuse('bad-1', Integrations::Medelement::ReceptionsSyncService::InvalidReceptionError.new('patient-secret-name'))
      lines = []
      allow(Rails.logger).to receive(:warn) { |line| lines << line }

      service.perform

      expect(lines.join).to include('hook=', 'entity_digest=', 'InvalidReceptionError')
      expect(lines.join).not_to include('bad-1')
      expect(lines.join).not_to include('patient-secret-name')
    end

    it 'still stops on an error that is not a refusal of one reception, and keeps the cursor' do
      allow(client).to receive(:receptions_by_update_date).and_return([{ 'RECEPTION_CODE' => 'bad-1' }, { 'RECEPTION_CODE' => 'good-1' }])
      refuse('bad-1', StandardError.new('database is gone'))

      expect { service.perform }.to raise_error(StandardError, 'database is gone')
      expect(Integrations::Medelement::SyncCursor.find_by!(hook: hook, name: 'receptions_delta').last_success_at).to be_nil
    end

    it 'is the same list of refusals the stale status reconciliation skips' do
      expect(Integrations::Medelement::StaleStatusReconciler::SKIPPED_ERRORS).to equal(described_class::SKIPPED_ERRORS)
    end
  end

  describe 'through the real import' do
    let!(:doctor) do
      create(:scheduling_resource, account: account, timezone: 'Asia/Almaty',
                                   custom_attributes: { 'medelement_specialist_code' => 'doctor-1',
                                                        'medelement_cabinets' => [{ 'company_cabinet_code' => 'cabinet-1' }] })
    end

    before do
      hook.update!(settings: hook.settings.merge('sync_patients' => false))
      allow(Integrations::Medelement::ReceptionsSyncService).to receive(:new).and_call_original
      allow(client).to receive(:get_reception) do |reception_code:, **|
        ends_at = reception_code == 'bad-1' ? '2026-10-07 09:00:00' : '2026-10-07 10:20:00'
        detail_for(reception_code).except('COMPANY_CABINET_CODE').merge('ENDTIME' => ends_at)
      end
    end

    it 'imports the receptions after one whose time range is invalid, and counts the invalid one as skipped' do
      allow(client).to receive(:receptions_by_update_date).and_return([{ 'RECEPTION_CODE' => 'bad-1' }, { 'RECEPTION_CODE' => 'good-1' }])

      result = service.perform

      expect(result).to include(changed_codes: 2, applied: 1, skipped: 1, complete: true)
      expect(Scheduling::Appointment.where(external_ref: 'medelement:reception:bad-1')).to be_empty
      expect(Scheduling::Appointment.find_by!(external_ref: 'medelement:reception:good-1')).to have_attributes(resource_id: doctor.id)
    end
  end

  it 'uses the sync_near priority lane when constructing its default MedElement client' do
    expect(Integrations::Medelement::Client).to receive(:new)
      .with(hash_including(lane: :sync_near)).and_return(client)

    described_class.new(hook: hook)
  end

  it 'processes unseen reception codes ahead of previously seen codes while still applying secondary overlap updates' do
    Integrations::Medelement::DeltaSeenReception.create!(
      hook: hook,
      reception_code: 'reception-001',
      change_marker: 'stale-marker',
      processed_at: 2.minutes.ago
    )
    entries = [{ 'RECEPTION_CODE' => 'reception-001' }, { 'RECEPTION_CODE' => 'reception-002' }]
    allow(client).to receive(:receptions_by_update_date).and_return(entries)
    fetched_order = []
    allow(client).to receive(:get_reception) do |reception_code:, **|
      fetched_order << reception_code
      detail_for(reception_code)
    end

    result = service.perform

    expect(fetched_order).to eq(%w[reception-002 reception-001])
    expect(result).to include(changed_codes: 2, applied: 2, skipped: 0, complete: true)
  end

  it 'keeps the cursor fixed when MAX_CHANGED stops mid-backlog before previously seen codes are verified' do
    stub_const("#{described_class}::MAX_CHANGED", 1)
    cursor = Integrations::Medelement::SyncCursor.create!(
      hook: hook, name: described_class::CURSOR_NAME, value: 15.minutes.ago, last_success_at: 15.minutes.ago
    )
    original_cursor_value = cursor.value
    Integrations::Medelement::DeltaSeenReception.create!(
      hook: hook, reception_code: 'reception-001', change_marker: 'stale-marker', processed_at: 2.minutes.ago
    )
    allow(client).to receive(:receptions_by_update_date).and_return(
      [{ 'RECEPTION_CODE' => 'reception-001' }, { 'RECEPTION_CODE' => 'reception-002' }]
    )
    allow(client).to receive(:get_reception) { |reception_code:, **| detail_for(reception_code) }

    first_poll = service.perform
    expect(first_poll).to include(changed_codes: 2, applied: 1, skipped: 0, complete: false)
    expect(cursor.reload.value).to be_within(1.second).of(original_cursor_value)

    second_poll = service.perform
    expect(second_poll).to include(changed_codes: 2, applied: 1, skipped: 0, complete: false)
    expect(cursor.reload.value).to be_within(1.second).of(original_cursor_value)

    third_poll = service.perform
    expect(third_poll).to include(changed_codes: 2, applied: 0, skipped: 2, complete: true)
    expect(cursor.reload.value).to be > original_cursor_value
  end

  it 'does not call MedElement or reconcile absences when the flag is off' do
    hook.update!(settings: hook.settings.merge('incremental_receptions_enabled' => false))

    expect(service.perform).to eq(:disabled)
    expect(client).not_to have_received(:get_reception)
    expect(Integrations::Medelement::MissingAppointmentReconciler).not_to receive(:new)
  end
end
