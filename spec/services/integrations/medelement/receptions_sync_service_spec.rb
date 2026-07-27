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
      time_zone: 'Asia/Almaty'
    )
  end
  let(:service) { described_class.new(account: account, client: client, configuration: configuration) }
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
