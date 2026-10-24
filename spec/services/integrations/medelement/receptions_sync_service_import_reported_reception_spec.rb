require 'rails_helper'

# MedElement's single-reception detail (v2) has no COMPANY_CABINET_CODE, visit status name or payment fields: those only come
# with the list. These specs import such a detail through the real importer.
RSpec.describe Integrations::Medelement::ReceptionsSyncService, '#import_reported_reception!' do
  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:hook) do
    create(:integrations_hook, :medelement, account: account).tap do |record|
      record.update!(settings: record.settings.merge('sync_patients' => false))
    end
  end
  let(:configuration) { Integrations::Medelement::Configuration.new(hook: hook) }
  let(:client) { instance_double(Integrations::Medelement::Client) }
  let(:service) { described_class.new(account: account, client: client, configuration: configuration) }
  let(:out_of_scope) { described_class::OutOfScope }
  let!(:single_cabinet_doctor) do
    create(:scheduling_resource, account: account, timezone: 'Asia/Almaty',
                                 custom_attributes: { 'medelement_specialist_code' => 'doctor-1',
                                                      'medelement_cabinets' => [{ 'company_cabinet_code' => 'cabinet-1' }] })
  end
  let!(:multi_cabinet_doctor) do
    create(:scheduling_resource, account: account, timezone: 'Asia/Almaty',
                                 custom_attributes: { 'medelement_specialist_code' => 'doctor-2',
                                                      'medelement_cabinets' => [{ 'company_cabinet_code' => 'cabinet-2' },
                                                                                { 'company_cabinet_code' => 'cabinet-3' }] })
  end

  # The real v2 keys of a detail: no COMPANY_CABINET_CODE, no visit status name, no PAID.
  def detail(code = 'reception-1', **overrides)
    {
      'RECEPTION_CODE' => code, 'PROFILE_CODE' => 'patient-1', 'COMPANY_CODE' => 'company-1', 'SPECIALIST_CODE' => 'doctor-1',
      'SPECIALIST_FULLNAME' => 'Doctor One', 'PATIENT_FULLNAME' => 'Patient One', 'CABINET_TYPE_NAME' => 'Therapy',
      'STARTTIME' => '2026-10-07 10:00:00', 'ENDTIME' => '2026-10-07 10:20:00', 'SERVICES' => [], 'ACTIVE' => 1, 'REMOVED' => 0,
      'COLOR_CODE' => '#fff'
    }.merge(overrides)
  end

  def existing_appointment(code = 'reception-1', resource: single_cabinet_doctor, **attributes)
    custom_attributes = attributes.delete(:custom_attributes) || {}
    create(:scheduling_appointment, account: account, resource: resource, source: 'medelement', status: 'scheduled',
                                    starts_at: Time.utc(2026, 10, 7, 5, 0), external_ref: "medelement:reception:#{code}",
                                    custom_attributes: custom_attributes, **attributes)
  end

  def refusal_reason
    yield
  rescue described_class::OutOfScopeReception => e
    e.reason
  end

  describe 'an existing appointment of the specialist' do
    let!(:appointment) do
      existing_appointment(
        resource: multi_cabinet_doctor, status: 'confirmed', service_amount: 20_000, prepaid_amount: 5000,
        payment_status: 'prepaid',
        custom_attributes: { 'medelement_cabinet_code' => 'cabinet-3', 'medelement_source_created_at' => '2026-10-01 09:00:00' }
      )
    end

    it 'is imported with the cabinet it has, and keeps its payment and financial attributes' do
      appointment.update!(settlement_amount: 1500)
      before = appointment.reload.slice(:service_amount, :prepaid_amount, :settlement_amount, :payment_status)

      service.import_reported_reception!(detail('reception-1', 'SPECIALIST_CODE' => 'doctor-2', 'ACTIVE' => 0))

      expect(appointment.reload).to have_attributes(status: 'completed', resource_id: multi_cabinet_doctor.id)
      expect(appointment.slice(:service_amount, :prepaid_amount, :settlement_amount, :payment_status)).to eq(before)
      expect(appointment.custom_attributes).to include(
        'medelement_cabinet_code' => 'cabinet-3', 'medelement_source_created_at' => '2026-10-01 09:00:00',
        'medelement_specialist_code' => 'doctor-2'
      )
    end

    it 'does not take another provider amount over a recorded payment' do
      row = { 'NOMENCLATURE_CODE' => 'nomenclature-1', 'PRICE' => 99_000, 'QUANTITY' => 1 }

      service.import_reported_reception!(detail('reception-1', 'SPECIALIST_CODE' => 'doctor-2', 'SERVICES' => [row]))

      expect(appointment.reload).to have_attributes(service_amount: 20_000, prepaid_amount: 5000, payment_status: 'prepaid')
    end

    it 'keeps the service amount of an unpaid appointment when the detail has no priced service rows' do
      unpaid = existing_appointment('reception-2', service_amount: 30_000)

      service.import_reported_reception!(detail('reception-2', 'ACTIVE' => 0))

      expect(unpaid.reload).to have_attributes(status: 'completed', service_amount: 30_000, prepaid_amount: 0,
                                               settlement_amount: 0, payment_status: 'awaiting_payment')
    end

    it 'is imported when it has no stored cabinet, without inventing one' do
      bare = existing_appointment('reception-2', resource: multi_cabinet_doctor)

      service.import_reported_reception!(detail('reception-2', 'SPECIALIST_CODE' => 'doctor-2', 'ACTIVE' => 0))

      expect(bare.reload.status).to eq('completed')
      expect(bare.custom_attributes).not_to have_key('medelement_cabinet_code')
    end

    it 'does not get a cabinet from a single-cabinet specialist either: the cabinet of a created reception never changes' do
      bare = existing_appointment('reception-2')

      service.import_reported_reception!(detail('reception-2', 'ACTIVE' => 0))

      expect(bare.reload.status).to eq('completed')
      expect(bare.custom_attributes).not_to have_key('medelement_cabinet_code')
    end

    it 'neither checks nor compares the cabinet: it keeps the stored one whatever cabinet the detail or the update list names' do
      [['reception-2', 'cabinet-2'], ['reception-3', 'not-a-cabinet-of-the-doctor']].each do |code, named|
        existing_appointment(code, resource: multi_cabinet_doctor, custom_attributes: { 'medelement_cabinet_code' => 'cabinet-3' })

        service.import_reported_reception!(
          detail(code, 'SPECIALIST_CODE' => 'doctor-2', 'COMPANY_CABINET_CODE' => named, 'ACTIVE' => 0), entry_cabinet_code: 'cabinet-2'
        )

        imported = account.scheduling_appointments.find_by!(external_ref: "medelement:reception:#{code}")
        expect(imported).to have_attributes(status: 'completed', resource_id: multi_cabinet_doctor.id)
        expect(imported.custom_attributes).to include('medelement_cabinet_code' => 'cabinet-3')
      end
    end

    it 'is out of scope with the cabinet unknown when it belongs to another specialist' do
      elsewhere = existing_appointment('reception-2', resource: single_cabinet_doctor)

      reason = refusal_reason { service.import_reported_reception!(detail('reception-2', 'SPECIALIST_CODE' => 'doctor-2')) }

      expect(reason).to eq(:cabinet_unknown)
      expect(elsewhere.reload).to have_attributes(status: 'scheduled', resource_id: single_cabinet_doctor.id)
    end
  end

  describe 'a new reception' do
    it 'of a specialist with one cabinet is imported with that cabinet' do
      service.import_reported_reception!(detail('reception-9'))

      expect(account.scheduling_appointments.find_by!(external_ref: 'medelement:reception:reception-9')).to have_attributes(
        status: 'scheduled', resource_id: single_cabinet_doctor.id, source: 'medelement', payment_status: 'awaiting_payment',
        custom_attributes: hash_including('medelement_cabinet_code' => 'cabinet-1')
      )
    end

    it 'of a specialist with several cabinets is out of scope with the cabinet unknown, and imports nothing' do
      reason = refusal_reason { service.import_reported_reception!(detail('reception-9', 'SPECIALIST_CODE' => 'doctor-2')) }

      expect(reason).to eq(:cabinet_unknown)
      expect(account.scheduling_appointments.where(external_ref: 'medelement:reception:reception-9')).to be_empty
    end

    it 'of such a specialist is imported with the cabinet the update list reported for it' do
      service.import_reported_reception!(detail('reception-9', 'SPECIALIST_CODE' => 'doctor-2'), entry_cabinet_code: 'cabinet-3')

      expect(account.scheduling_appointments.find_by!(external_ref: 'medelement:reception:reception-9')).to have_attributes(
        resource_id: multi_cabinet_doctor.id, custom_attributes: hash_including('medelement_cabinet_code' => 'cabinet-3')
      )
    end

    it 'is refused when the cabinet the update list reported is not a cabinet of the specialist' do
      reason = refusal_reason do
        service.import_reported_reception!(detail('reception-9', 'SPECIALIST_CODE' => 'doctor-2'), entry_cabinet_code: 'cabinet-1')
      end

      expect(reason).to eq(:cabinet_mismatch)
      expect(account.scheduling_appointments.where(external_ref: 'medelement:reception:reception-9')).to be_empty
    end
  end

  describe 'what is still refused' do
    it 'refuses a new reception whose detail names a cabinet that is not the specialist cabinet' do
      reason = refusal_reason { service.import_reported_reception!(detail('reception-9', 'COMPANY_CABINET_CODE' => 'cabinet-3')) }

      expect(reason).to eq(:cabinet_mismatch)
      expect(account.scheduling_appointments.where(external_ref: 'medelement:reception:reception-9')).to be_empty
    end

    it 'refuses a reception that exists under another specialist, when the cabinet is not that of the new specialist' do
      elsewhere = existing_appointment('reception-2', resource: single_cabinet_doctor)

      reason = refusal_reason do
        service.import_reported_reception!(detail('reception-2', 'SPECIALIST_CODE' => 'doctor-2', 'COMPANY_CABINET_CODE' => 'cabinet-1'))
      end

      expect(reason).to eq(:cabinet_mismatch)
      expect(elsewhere.reload).to have_attributes(status: 'scheduled', resource_id: single_cabinet_doctor.id)
    end

    it 'takes the cabinet of the detail over the one the update list reported' do
      reason = refusal_reason do
        service.import_reported_reception!(detail('reception-1', 'COMPANY_CABINET_CODE' => 'cabinet-3'), entry_cabinet_code: 'cabinet-1')
      end

      expect(reason).to eq(:cabinet_mismatch)
    end

    it 'imports a detail whose cabinet is the specialist cabinet' do
      service.import_reported_reception!(detail('reception-9', 'COMPANY_CABINET_CODE' => 'cabinet-1'))

      expect(account.scheduling_appointments.find_by!(external_ref: 'medelement:reception:reception-9').custom_attributes)
        .to include('medelement_cabinet_code' => 'cabinet-1')
    end

    it 'refuses a specialist that is not mapped, with or without an appointment' do
      appointment = existing_appointment
      unmapped = detail('reception-1', 'SPECIALIST_CODE' => 'left-the-clinic')

      expect(refusal_reason { service.import_reported_reception!(unmapped) }).to eq(:specialist_not_mapped)
      expect(refusal_reason { service.import_reported_reception!(unmapped.merge('RECEPTION_CODE' => 'reception-9')) })
        .to eq(:specialist_not_mapped)
      expect(appointment.reload.status).to eq('scheduled')
    end
  end

  describe 'the status of a detail without visit status name' do
    let(:no_show_audit) do
      { 'source' => 'medelement_reception_sync', 'previous_status' => 'scheduled', 'status' => 'no_show',
        'reason' => 'provider_explicit_no_show', 'raw_status' => 'неявка', 'observed_at' => '2026-10-07T12:00:00Z' }
    end

    it 'keeps the explicit outcome MedElement gave earlier, also for a reception that is still active' do
      appointment = existing_appointment(status: 'no_show', custom_attributes: { 'provider_status_audit' => no_show_audit })

      service.import_reported_reception!(detail)

      expect(appointment.reload.status).to eq('no_show')
      expect(appointment.custom_attributes['provider_status_audit']).to include('reason' => 'provider_explicit_no_show', 'status' => 'no_show')
    end

    it 'does not keep an outcome that was changed locally afterwards' do
      appointment = existing_appointment(status: 'confirmed', custom_attributes: { 'provider_status_audit' => no_show_audit })

      service.import_reported_reception!(detail)

      expect(appointment.reload.status).to eq('confirmed')
    end

    it 'takes the status the detail names itself' do
      appointment = existing_appointment(status: 'no_show', custom_attributes: { 'provider_status_audit' => no_show_audit })

      service.import_reported_reception!(detail('reception-1', 'VISIT_STATUS_NAME' => 'завершена'))

      expect(appointment.reload.status).to eq('completed')
    end

    it 'still cancels a removed reception and maps ACTIVE 0 to completed and ACTIVE 1 to scheduled for an open one' do
      removed = existing_appointment('removed-1', status: 'no_show', custom_attributes: { 'provider_status_audit' => no_show_audit })
      closed = existing_appointment('closed-1')
      open = existing_appointment('open-1', status: 'confirmed')

      service.import_reported_reception!(detail('removed-1', 'REMOVED' => 1))
      service.import_reported_reception!(detail('closed-1', 'ACTIVE' => 0))
      service.import_reported_reception!(detail('open-1'))

      expect([removed, closed, open].map { |appointment| appointment.reload.status }).to eq(%w[cancelled completed confirmed])
    end

    it 'does not close a reception whose detail does not say whether it is active' do
      appointment = existing_appointment

      service.import_reported_reception!(detail.except('ACTIVE'))

      expect(appointment.reload.status).to eq('scheduled')
    end
  end

  describe '#preview_reported_status' do
    it 'gives the status of the import for a detail without cabinet, and the reason it would refuse one' do
      existing_appointment('closed-1')
      existing_appointment('foreign-1')
      existing_appointment('stray-1', resource: single_cabinet_doctor)

      expect(service.preview_reported_status(detail('closed-1', 'ACTIVE' => 0))).to eq('completed')
      expect(service.preview_reported_status(detail('foreign-1', 'SPECIALIST_CODE' => 'left-the-clinic')))
        .to eq(out_of_scope.new(reason: :specialist_not_mapped))
      expect(service.preview_reported_status(detail('stray-1', 'SPECIALIST_CODE' => 'doctor-2')))
        .to eq(out_of_scope.new(reason: :cabinet_unknown))
      expect(service.preview_reported_status(detail('stray-1', 'SPECIALIST_CODE' => 'doctor-2', 'COMPANY_CABINET_CODE' => 'cabinet-1')))
        .to eq(out_of_scope.new(reason: :cabinet_mismatch))
    end

    it 'does not compare the cabinet of an appointment that is the specialist own, as the import does not' do
      existing_appointment('own-1')

      expect(service.preview_reported_status(detail('own-1', 'COMPANY_CABINET_CODE' => 'cabinet-3', 'ACTIVE' => 0))).to eq('completed')
      expect(service.preview_reported_status(detail('own-1', 'COMPANY_CABINET_CODE' => 'cabinet-3'), entry_cabinet_code: 'cabinet-9'))
        .to eq('scheduled')
    end

    it 'uses the cabinet of the update list like the import' do
      existing_appointment('stray-1', resource: single_cabinet_doctor)
      stray = detail('stray-1', 'SPECIALIST_CODE' => 'doctor-2')

      expect(service.preview_reported_status(stray, entry_cabinet_code: 'cabinet-2')).to eq('scheduled')
      expect(service.preview_reported_status(stray, entry_cabinet_code: 'cabinet-1')).to eq(out_of_scope.new(reason: :cabinet_mismatch))
    end

    it 'keeps an earlier explicit outcome like the import does' do
      existing_appointment(
        status: 'no_show', custom_attributes: { 'provider_status_audit' => { 'status' => 'no_show', 'reason' => 'provider_explicit_no_show' } }
      )

      expect(service.preview_reported_status(detail)).to eq('no_show')
    end

    it 'writes nothing' do
      appointment = existing_appointment

      expect { service.preview_reported_status(detail('reception-1', 'ACTIVE' => 0)) }.not_to(change { appointment.reload.attributes })
    end
  end
end
