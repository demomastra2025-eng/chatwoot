require 'rails_helper'

RSpec.describe Integrations::Medelement::ReceptionsSyncService do
  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }
  let(:configuration) { Integrations::Medelement::Configuration.new(hook: hook) }
  let(:client) { instance_double(Integrations::Medelement::Client) }
  let(:importer) { instance_double(Integrations::Medelement::AppointmentImporterService) }

  before do
    hook.update!(settings: hook.settings.merge('sync_patients' => false))
    allow(importer).to receive(:external_ref_for).and_return('medelement:reception:reception-1')
    allow(importer).to receive(:upsert!).and_return(true)
    allow(Integrations::Medelement::AppointmentImporterService).to receive(:new).and_return(importer)
    create(:scheduling_resource, account: account, timezone: 'Asia/Almaty',
                                 custom_attributes: {
                                   'medelement_specialist_code' => 'doctor-1',
                                   'medelement_cabinets' => [{ 'company_cabinet_code' => 'cabinet-1' }]
                                 })
  end

  it 'passes the fetched detail through the normal appointment importer without absence reconciliation' do
    detail = {
      'RECEPTION_CODE' => 'reception-1', 'PROFILE_CODE' => 'patient-1',
      'SPECIALIST_CODE' => 'doctor-1', 'COMPANY_CABINET_CODE' => 'cabinet-1',
      'STARTTIME' => '2026-10-07 10:00:00', 'ENDTIME' => '2026-10-07 10:20:00', 'SERVICES' => []
    }
    service = described_class.new(account: account, client: client, configuration: configuration)

    expect(Integrations::Medelement::MissingAppointmentReconciler).not_to receive(:new)
    service.import_reported_reception!(detail)

    expect(importer).to have_received(:upsert!).with(
      hash_including(reception: hash_including('RECEPTION_CODE' => 'reception-1', 'PATIENT_CODE' => 'patient-1'),
                     import_context: hash_including(specialist_code: 'doctor-1'))
    )
  end

  it 'marks the detail as read without the list and gives the importer the cabinet it resolved' do
    detail = {
      'RECEPTION_CODE' => 'reception-1', 'PROFILE_CODE' => 'patient-1', 'SPECIALIST_CODE' => 'doctor-1',
      'STARTTIME' => '2026-10-07 10:00:00', 'ENDTIME' => '2026-10-07 10:20:00', 'SERVICES' => []
    }
    service = described_class.new(account: account, client: client, configuration: configuration)

    service.import_reported_reception!(detail)

    expect(importer).to have_received(:upsert!).with(
      hash_including(reception: hash_including('COMPANY_CABINET_CODE' => 'cabinet-1', '_MEDELEMENT_DETAIL_ONLY' => true))
    )
  end

  it 'hands the importer no cabinet for a reception OneLink already has on the specialist resource' do
    doctor = account.scheduling_resources.find_by!("custom_attributes ->> 'medelement_specialist_code' = 'doctor-1'")
    create(:scheduling_appointment, account: account, external_ref: 'medelement:reception:reception-1', resource: doctor)
    detail = {
      'RECEPTION_CODE' => 'reception-1', 'PROFILE_CODE' => 'patient-1', 'SPECIALIST_CODE' => 'doctor-1',
      'COMPANY_CABINET_CODE' => 'another-cabinet', 'STARTTIME' => '2026-10-07 10:00:00', 'ENDTIME' => '2026-10-07 10:20:00',
      'SERVICES' => []
    }
    service = described_class.new(account: account, client: client, configuration: configuration)

    service.import_reported_reception!(detail)

    expect(importer).to have_received(:upsert!).with(
      hash_including(reception: satisfy { |reception| !reception.key?('COMPANY_CABINET_CODE') })
    )
  end

  it 'uses the existing reconciler only for an explicitly removed reception' do
    appointment = create(:scheduling_appointment, account: account, external_ref: 'medelement:reception:reception-1')
    reconciler = instance_double(Integrations::Medelement::MissingAppointmentReconciler, perform: true)
    allow(Integrations::Medelement::MissingAppointmentReconciler).to receive(:new).and_return(reconciler)
    service = described_class.new(account: account, client: client, configuration: configuration)

    service.import_reported_reception!({ 'RECEPTION_CODE' => 'reception-1', 'REMOVED' => 1 })

    expect(Integrations::Medelement::MissingAppointmentReconciler).to have_received(:new).with(
      appointment: appointment, snapshot_version: appointment.updated_at, provider_removal_confirmed: true
    )
    expect(reconciler).to have_received(:perform).once
    expect(importer).not_to have_received(:upsert!)
  end

  describe '#preview_reported_status' do
    let(:detail) do
      {
        'RECEPTION_CODE' => 'reception-1', 'PROFILE_CODE' => 'patient-1',
        'SPECIALIST_CODE' => 'doctor-1', 'COMPANY_CABINET_CODE' => 'cabinet-1',
        'STARTTIME' => '2026-10-07 10:00:00', 'ENDTIME' => '2026-10-07 10:20:00', 'SERVICES' => [], 'ACTIVE' => 0
      }
    end
    let(:service) { described_class.new(account: account, client: client, configuration: configuration) }

    before { allow(importer).to receive(:provider_status_for).and_return('completed') }

    it 'is absent when OneLink has no appointment for the reception' do
      expect(service.preview_reported_status(detail)).to eq(:absent)
    end

    context 'with an appointment' do
      let!(:appointment) do
        create(:scheduling_appointment, account: account, external_ref: 'medelement:reception:reception-1')
      end

      it 'gives the importer status for the reported reception and imports nothing' do
        expect(service.preview_reported_status(detail)).to eq('completed')

        expect(importer).to have_received(:provider_status_for).with(
          appointment, hash_including('RECEPTION_CODE' => 'reception-1', 'PATIENT_CODE' => 'patient-1')
        )
        expect(importer).not_to have_received(:upsert!)
      end

      it 'says cancelled for a removed reception, as the import does' do
        expect(service.preview_reported_status(detail.merge('REMOVED' => 1))).to eq('cancelled')
      end

      it 'says out of scope, and why, when the specialist or cabinet is not mapped' do
        out_of_scope = described_class::OutOfScope
        expect(service.preview_reported_status(detail.merge('SPECIALIST_CODE' => 'unknown')))
          .to eq(out_of_scope.new(reason: :specialist_not_mapped))
        expect(service.preview_reported_status(detail.merge('COMPANY_CABINET_CODE' => 'unknown')))
          .to eq(out_of_scope.new(reason: :cabinet_mismatch))
        expect(importer).not_to have_received(:provider_status_for)
      end

      it 'resolves a detail without cabinet like the import does and hands the importer the cabinet' do
        service.preview_reported_status(detail.except('COMPANY_CABINET_CODE'))

        expect(importer).to have_received(:provider_status_for).with(
          appointment, hash_including('COMPANY_CABINET_CODE' => 'cabinet-1', '_MEDELEMENT_DETAIL_ONLY' => true)
        )
      end

      it 'hands the importer no cabinet for the specialist own appointment, so that the stored cabinet stays' do
        appointment.update!(resource: account.scheduling_resources.find_by!("custom_attributes ->> 'medelement_specialist_code' = 'doctor-1'"))

        service.preview_reported_status(detail.merge('COMPANY_CABINET_CODE' => 'another-cabinet'), entry_cabinet_code: 'cabinet-1')

        expect(importer).to have_received(:provider_status_for).with(appointment, satisfy { |reception| !reception.key?('COMPANY_CABINET_CODE') })
      end
    end
  end

  it 'does not audit a full sweep detail refresh that changed only sync metadata' do
    hook.update!(settings: hook.settings.merge('incremental_receptions_enabled' => true))
    Integrations::Medelement::SyncCursor.create!(
      hook: hook, name: 'receptions_delta', value: 1.minute.ago, last_success_at: Time.current
    )
    appointment = instance_double(
      Scheduling::Appointment,
      previous_changes: {
        'custom_attributes' => [
          {},
          {
            'medelement_detail_synced_at' => Time.current.iso8601,
            'provider_status_audit' => { 'observed_at' => Time.current.iso8601 }
          }
        ],
        'updated_at' => [1.minute.ago, Time.current]
      }
    )
    service = described_class.new(account: account, client: client, configuration: configuration, hook: hook)

    service.send(:audit_change!, appointment, 'RECEPTION_CODE' => 'reception-1')

    expect(Integrations::Medelement::DeltaMissCandidate.where(hook: hook)).to be_empty
  end
end
