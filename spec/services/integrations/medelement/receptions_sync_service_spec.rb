require 'rails_helper'

RSpec.describe Integrations::Medelement::ReceptionsSyncService do
  include ActiveSupport::Testing::TimeHelpers

  let(:account) { create(:account) }
  let(:client) { instance_double(Integrations::Medelement::Client) }
  let(:configuration) do
    instance_double(
      Integrations::Medelement::Configuration,
      sync_patients?: false,
      receptions_days_back: 3,
      receptions_days_forward: 70,
      throttle_ms: 0,
      time_zone: 'Asia/Almaty',
      organization_id: 'company-1'
    )
  end
  let(:conflict_tracker) { instance_double(Integrations::Medelement::ConflictTracker, record!: true) }
  let(:service) do
    described_class.new(
      account: account,
      client: client,
      configuration: configuration,
      conflict_tracker: conflict_tracker
    )
  end
  let!(:resource) do
    create(
      :scheduling_resource,
      account: account,
      timezone: 'Asia/Almaty',
      custom_attributes: {
        'medelement_specialist_code' => '27492901726817790',
        'medelement_cabinets' => [{ 'companyCabinetCode' => '37413011726129875' }]
      }
    )
  end
  let(:reception_payload) do
    [
      {
        'RECEPTION_CODE' => '975592971773905133',
        'PATIENT_CODE' => '550990851604984873',
        'STARTTIME' => '2026-03-21 09:00:00',
        'ENDTIME' => '2026-03-21 09:20:00',
        'ACTIVE' => 1,
        'REMOVED' => 0,
        'CREATED_AT' => '2026-03-19 12:25:33',
        'COMPANY_CABINET_CODE' => '37413011726129875'
      }
    ]
  end

  before do
    allow(client).to receive(:get_receptions).and_return(reception_payload)
    allow(client).to receive(:get_reception) do |reception_code:, **|
      reception_payload.first.merge(
        'RECEPTION_CODE' => reception_code,
        'PROFILE_CODE' => reception_payload.first['PATIENT_CODE'],
        'COMPANY_CODE' => 'company-1',
        'SERVICES' => []
      )
    end
  end

  it 'imports the service and price from the provider reception detail' do
    provider_service = create(
      :scheduling_service,
      account: account,
      custom_attributes: { 'medelement_nomenclature_code' => 'service-1' }
    )
    allow(client).to receive(:get_reception).and_return(
      reception_payload.first.merge(
        'PROFILE_CODE' => reception_payload.first['PATIENT_CODE'],
        'COMPANY_CODE' => 'company-1',
        'SERVICES' => [
          {
            'NOMENCLATURE_CODE' => 'service-1',
            'PRICE' => 4000,
            'QUANTITY' => 1,
            'TOTAL_SUM' => 4000,
            'DELETED' => 0
          }
        ]
      )
    )

    service.perform

    appointment = account.scheduling_appointments.find_by!(source: 'medelement')
    expect(appointment).to have_attributes(service_id: provider_service.id, service_amount: 4000)
  end

  it 'fails closed when the provider detail does not describe the listed reception' do
    allow(client).to receive(:get_reception).and_return(
      reception_payload.first.merge(
        'RECEPTION_CODE' => 'another-reception',
        'PROFILE_CODE' => reception_payload.first['PATIENT_CODE'],
        'COMPANY_CODE' => 'company-1',
        'SERVICES' => []
      )
    )

    expect { service.perform }.to raise_error(
      described_class::IncompleteSnapshotError,
      /reception detail is incomplete/
    )
    expect(account.scheduling_appointments.where(source: 'medelement')).to be_empty
  end

  it 'fails closed when list and detail identify different patients' do
    allow(client).to receive(:get_reception).and_return(
      reception_payload.first.merge(
        'PROFILE_CODE' => 'another-patient',
        'COMPANY_CODE' => 'company-1',
        'SERVICES' => []
      )
    )

    expect { service.perform }.to raise_error(
      described_class::IncompleteSnapshotError,
      /reception detail is incomplete/
    )
    expect(account.scheduling_appointments.where(source: 'medelement')).to be_empty
  end

  it 'fails closed when the detail omits the provider organization marker' do
    allow(client).to receive(:get_reception).and_return(
      reception_payload.first.merge(
        'PROFILE_CODE' => reception_payload.first['PATIENT_CODE'],
        'SERVICES' => []
      )
    )

    expect { service.perform }.to raise_error(
      described_class::IncompleteSnapshotError,
      /reception detail scope is invalid/
    )
    expect(account.scheduling_appointments.where(source: 'medelement')).to be_empty
  end

  it 'creates imported appointments without touching overlapping manual appointments' do
    travel_to(Time.zone.parse('2026-03-20 10:00:00')) do
      create(
        :scheduling_appointment,
        account: account,
        resource: resource,
        starts_at: ActiveSupport::TimeZone['Asia/Almaty'].local(2026, 3, 21, 9, 0, 0),
        ends_at: ActiveSupport::TimeZone['Asia/Almaty'].local(2026, 3, 21, 9, 20, 0)
      )

      expect { service.perform }.to change { account.scheduling_appointments.where(source: 'medelement').count }.by(1)
      expect(account.scheduling_appointments.where(source: 'manual').count).to eq(1)
    end
  end

  it 'does not restore a cancelled appointment from a snapshot captured before the Captain mutation' do
    appointment = create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      created_by: create(:user, account: account),
      source: 'manual',
      external_ref: 'medelement:reception:975592971773905133',
      custom_attributes: {
        'medelement_reception_code' => '975592971773905133',
        'medelement_cabinet_code' => '37413011726129875'
      }
    )
    assistant = create(:captain_assistant, account: account)

    travel_to(Time.zone.parse('2026-03-20 10:00:00')) do
      allow(client).to receive(:get_reception) do |reception_code:, **|
        travel 1.second
        Scheduling::Appointments::UpsertService.new(
          account: account,
          appointment: appointment,
          params: { status: 'cancelled' },
          actor: assistant
        ).perform

        reception_payload.first.merge(
          'RECEPTION_CODE' => reception_code,
          'PROFILE_CODE' => reception_payload.first['PATIENT_CODE'],
          'COMPANY_CODE' => 'company-1',
          'SERVICES' => []
        )
      end

      expect(service.perform).to include(imported_count: 0, skipped_count: 1)
    end

    expect(appointment.reload.status).to eq('cancelled')
    expect(conflict_tracker).to have_received(:record!).with(hash_including(conflict_type: 'stale_snapshot'))
  end

  it 'requires two complete snapshots before tombstoning a missing Medelement appointment' do
    travel_to(Time.zone.parse('2026-03-20 10:00:00')) do
      stale_imported = create(
        :scheduling_appointment,
        account: account,
        resource: resource,
        source: 'medelement',
        external_ref: 'medelement:reception:old',
        starts_at: ActiveSupport::TimeZone['Asia/Almaty'].local(2026, 3, 22, 9, 0, 0),
        ends_at: ActiveSupport::TimeZone['Asia/Almaty'].local(2026, 3, 22, 9, 20, 0),
        client_name: 'Imported'
      )
      manual = create(
        :scheduling_appointment,
        account: account,
        resource: resource,
        starts_at: ActiveSupport::TimeZone['Asia/Almaty'].local(2026, 3, 22, 9, 30, 0),
        ends_at: ActiveSupport::TimeZone['Asia/Almaty'].local(2026, 3, 22, 10, 0, 0)
      )

      service.perform

      stale_imported.reload
      expect(stale_imported.status).to eq('scheduled')
      expect(stale_imported.custom_attributes['medelement_missing_syncs']).to eq(1)

      service.perform

      stale_imported.reload
      expect(stale_imported.status).to eq('cancelled')
      expect(stale_imported.payment_status).to eq('cancelled')
      expect(stale_imported.custom_attributes['source_mode']).to eq('provider_tombstone')
      expect(stale_imported.custom_attributes['medelement_removed_at']).to be_present
      expect(account.scheduling_appointments.exists?(manual.id)).to be(true)
    end
  end

  it 'restores a tombstoned appointment when it reappears in a complete snapshot' do
    travel_to(Time.zone.parse('2026-03-20 10:00:00')) do
      appointment = create(
        :scheduling_appointment,
        account: account,
        resource: resource,
        source: 'medelement',
        external_ref: 'medelement:reception:restored',
        starts_at: ActiveSupport::TimeZone['Asia/Almaty'].local(2026, 3, 22, 9, 0, 0),
        ends_at: ActiveSupport::TimeZone['Asia/Almaty'].local(2026, 3, 22, 9, 20, 0),
        client_name: 'Imported'
      )
      allow(client).to receive(:get_receptions).and_return([])

      service.perform
      service.perform

      expect(appointment.reload.status).to eq('cancelled')

      restored_reception = reception_payload.first.merge('RECEPTION_CODE' => 'restored')
      allow(client).to receive(:get_receptions).and_return([restored_reception])

      service.perform

      appointment.reload
      expect(appointment.status).to eq('scheduled')
      expect(appointment.custom_attributes['source_mode']).to eq('imported')
      expect(appointment.custom_attributes).not_to include(
        'medelement_missing_since',
        'medelement_missing_syncs',
        'medelement_removed_at'
      )
    end
  end

  it 'fails closed without cleanup when a one-day provider snapshot is saturated' do
    travel_to(Time.zone.parse('2026-03-20 10:00:00')) do
      existing_import = create(
        :scheduling_appointment,
        account: account,
        resource: resource,
        source: 'medelement',
        external_ref: 'medelement:reception:existing',
        starts_at: ActiveSupport::TimeZone['Asia/Almaty'].local(2026, 3, 20, 11, 0, 0),
        ends_at: ActiveSupport::TimeZone['Asia/Almaty'].local(2026, 3, 20, 11, 20, 0),
        client_name: 'Imported'
      )
      allow(configuration).to receive(:receptions_days_back).and_return(0)
      allow(configuration).to receive(:receptions_days_forward).and_return(0)
      allow(client).to receive(:get_receptions).and_return(
        Array.new(described_class::MAX_RECEPTIONS_PER_REQUEST, reception_payload.first)
      )

      expect { service.perform }.to raise_error(described_class::IncompleteSnapshotError)

      expect(existing_import.reload.status).to eq('scheduled')
      expect(existing_import.custom_attributes).not_to include('medelement_missing_syncs')
    end
  end

  it 'skips a stale provider binding before API fetch without cleaning up a partial snapshot' do
    rejected_resource = create(
      :scheduling_resource,
      account: account,
      custom_attributes: {
        'medelement_specialist_code' => 'stale-specialist',
        'medelement_cabinets' => [{ 'companyCabinetCode' => 'stale-cabinet' }],
        'medelement_last_seen_at' => Time.zone.parse('2026-03-10 10:00:00').iso8601
      }
    )
    existing_import = create(
      :scheduling_appointment,
      account: account,
      resource: rejected_resource,
      source: 'medelement',
      external_ref: 'medelement:reception:existing',
      starts_at: ActiveSupport::TimeZone['Asia/Almaty'].local(2026, 3, 22, 11, 0, 0),
      ends_at: ActiveSupport::TimeZone['Asia/Almaty'].local(2026, 3, 22, 11, 20, 0),
      client_name: 'Imported'
    )
    travel_to(Time.zone.parse('2026-03-20 10:00:00')) do
      result = service.perform

      expect(result).to include(imported_count: 1, skipped_pair_count: 1)
      expect(existing_import.reload.custom_attributes).not_to include('medelement_missing_syncs')
      expect(client).not_to have_received(:get_receptions).with(hash_including(specialist_code: 'stale-specialist'))
      expect(conflict_tracker).to have_received(:record!).with(
        hash_including(
          phase: 'receptions',
          entity_type: 'specialist_cabinet',
          conflict_type: 'stale_provider_binding',
          severity: 'error'
        )
      )
    end
  end

  it 'skips a provider binding with a malformed last-seen timestamp without cleaning up a partial snapshot' do
    resource.update!(
      custom_attributes: resource.custom_attributes.merge('medelement_last_seen_at' => 'not-a-timestamp')
    )

    result = service.perform

    expect(result).to include(imported_count: 0, skipped_pair_count: 1)
    expect(client).not_to have_received(:get_receptions)
    expect(conflict_tracker).to have_received(:record!).with(
      hash_including(conflict_type: 'stale_provider_binding', severity: 'error')
    )
  end

  it 'does not poll an inactive Medelement specialist' do
    inactive_resource = create(
      :scheduling_resource,
      account: account,
      active: false,
      custom_attributes: {
        'medelement_specialist_code' => 'inactive-specialist',
        'medelement_cabinets' => [{ 'companyCabinetCode' => 'inactive-cabinet' }]
      }
    )

    result = service.perform

    expect(result).to include(imported_count: 1, skipped_pair_count: 0)
    expect(client).not_to have_received(:get_receptions).with(hash_including(specialist_code: 'inactive-specialist'))
    expect(inactive_resource.reload).not_to be_active
  end

  it 'still aborts the snapshot for retryable provider failures' do
    provider_error = Integrations::Medelement::Client::ApiError.new('Provider unavailable', status: 500)
    allow(client).to receive(:get_receptions).and_raise(provider_error)

    expect { service.perform }.to raise_error(provider_error)
    expect(conflict_tracker).not_to have_received(:record!)
  end

  it 'does not mask a provider rejection for a recently observed pair' do
    resource.update!(
      custom_attributes: resource.custom_attributes.merge('medelement_last_seen_at' => 1.hour.ago.iso8601)
    )
    provider_error = Integrations::Medelement::Client::ApiError.new('Provider request failed', status: 400)
    allow(client).to receive(:get_receptions).and_raise(provider_error)

    expect { service.perform }.to raise_error(provider_error)
    expect(conflict_tracker).not_to have_received(:record!)
  end

  it 'imports Medelement timestamps using Asia/Almaty as UTC+05' do
    travel_to(Time.zone.parse('2026-03-20 10:00:00')) do
      service.perform

      imported_appointment = account.scheduling_appointments.find_by!(source: 'medelement')

      expect(imported_appointment.starts_at.iso8601).to eq('2026-03-21T04:00:00Z')
      expect(imported_appointment.ends_at.iso8601).to eq('2026-03-21T04:20:00Z')
    end
  end

  it 'skips invalid receptions without aborting the whole sync or deleting known imported refs' do
    existing_invalid_import = create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      source: 'medelement',
      external_ref: 'medelement:reception:broken',
      starts_at: ActiveSupport::TimeZone['Asia/Almaty'].local(2026, 3, 22, 10, 0, 0),
      ends_at: ActiveSupport::TimeZone['Asia/Almaty'].local(2026, 3, 22, 10, 20, 0),
      client_name: 'Imported invalid placeholder'
    )

    allow(client).to receive(:get_receptions).and_return(
      [
        reception_payload.first,
        reception_payload.first.merge(
          'RECEPTION_CODE' => 'broken',
          'STARTTIME' => '2026-03-21 11:00:00',
          'ENDTIME' => '2026-03-21 11:00:00'
        )
      ]
    )

    travel_to(Time.zone.parse('2026-03-20 10:00:00')) do
      expect { service.perform }.not_to raise_error

      expect(account.scheduling_appointments.find_by!(external_ref: 'medelement:reception:broken').id).to eq(existing_invalid_import.id)
      expect(account.scheduling_appointments.find_by!(external_ref: 'medelement:reception:975592971773905133')).to be_present
      expect(account.scheduling_appointments.where(source: 'medelement').count).to eq(2)
    end
  end
end
