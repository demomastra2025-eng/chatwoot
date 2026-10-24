require 'rails_helper'

# MedElement's single-reception detail (v2) has no COMPANY_CABINET_CODE, visit status name or payment fields: those only come
# with the list. These specs import such a detail, and read a status from it, through the real importer.
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

  def imported(code)
    account.scheduling_appointments.find_by!(external_ref: "medelement:reception:#{code}")
  end

  describe 'an existing appointment' do
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

        expect(imported(code)).to have_attributes(status: 'completed', resource_id: multi_cabinet_doctor.id)
        expect(imported(code).custom_attributes).to include('medelement_cabinet_code' => 'cabinet-3')
      end
    end
  end

  describe 'an appointment that MedElement has moved to another specialist' do
    # The appointment is on the first doctor's resource, and the detail names the second doctor, who has two cabinets. Whatever
    # cabinet the detail, the update list or the second doctor's cabinets say, the stored cabinet stays: none is looked up,
    # compared or guessed for an appointment that already exists.
    it 'follows the specialist, keeps its stored cabinet and is not refused for the cabinets of the new specialist' do
      moved = existing_appointment('reception-2', custom_attributes: { 'medelement_cabinet_code' => 'cabinet-1' })

      service.import_reported_reception!(detail('reception-2', 'SPECIALIST_CODE' => 'doctor-2', 'ACTIVE' => 0))

      expect(moved.reload).to have_attributes(status: 'completed', resource_id: multi_cabinet_doctor.id)
      expect(moved.custom_attributes).to include('medelement_cabinet_code' => 'cabinet-1', 'medelement_specialist_code' => 'doctor-2')
    end

    it 'keeps the stored cabinet whatever cabinet the detail or the update list names' do
      [['reception-2', 'cabinet-2', 'cabinet-3'], ['reception-3', 'cabinet-1', 'not-a-cabinet']].each do |code, named, listed|
        existing_appointment(code, custom_attributes: { 'medelement_cabinet_code' => 'cabinet-1' })

        service.import_reported_reception!(
          detail(code, 'SPECIALIST_CODE' => 'doctor-2', 'COMPANY_CABINET_CODE' => named), entry_cabinet_code: listed
        )

        expect(imported(code)).to have_attributes(resource_id: multi_cabinet_doctor.id)
        expect(imported(code).custom_attributes).to include('medelement_cabinet_code' => 'cabinet-1')
      end
    end

    it 'does not get a cabinet when it has none, not even from a specialist with a single cabinet' do
      bare_moved_to_single = existing_appointment('reception-2', resource: multi_cabinet_doctor)
      bare_moved_to_multi = existing_appointment('reception-3')

      service.import_reported_reception!(detail('reception-2', 'SPECIALIST_CODE' => 'doctor-1'), entry_cabinet_code: 'cabinet-1')
      service.import_reported_reception!(detail('reception-3', 'SPECIALIST_CODE' => 'doctor-2'))

      expect(bare_moved_to_single.reload).to have_attributes(resource_id: single_cabinet_doctor.id)
      expect(bare_moved_to_multi.reload).to have_attributes(resource_id: multi_cabinet_doctor.id)
      expect([bare_moved_to_single, bare_moved_to_multi].map { |record| record.custom_attributes.key?('medelement_cabinet_code') })
        .to eq([false, false])
    end

    it 'is still refused when the new specialist is not mapped, as there is no resource to move it to' do
      moved = existing_appointment('reception-2')

      expect(refusal_reason { service.import_reported_reception!(detail('reception-2', 'SPECIALIST_CODE' => 'left-the-clinic')) })
        .to eq(:specialist_not_mapped)
      expect(moved.reload).to have_attributes(status: 'scheduled', resource_id: single_cabinet_doctor.id)
    end
  end

  describe 'a new reception' do
    it 'of a specialist with one cabinet is imported with that cabinet' do
      service.import_reported_reception!(detail('reception-9'))

      expect(imported('reception-9')).to have_attributes(
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

      expect(imported('reception-9')).to have_attributes(
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

    it 'is refused when its detail names a cabinet that is not the specialist cabinet' do
      reason = refusal_reason { service.import_reported_reception!(detail('reception-9', 'COMPANY_CABINET_CODE' => 'cabinet-3')) }

      expect(reason).to eq(:cabinet_mismatch)
      expect(account.scheduling_appointments.where(external_ref: 'medelement:reception:reception-9')).to be_empty
    end

    it 'takes the cabinet of the detail over the one the update list reported' do
      reason = refusal_reason do
        service.import_reported_reception!(detail('reception-9', 'COMPANY_CABINET_CODE' => 'cabinet-3'), entry_cabinet_code: 'cabinet-1')
      end

      expect(reason).to eq(:cabinet_mismatch)
    end

    it 'is imported when its detail names the specialist cabinet' do
      service.import_reported_reception!(detail('reception-9', 'COMPANY_CABINET_CODE' => 'cabinet-1'))

      expect(imported('reception-9').custom_attributes).to include('medelement_cabinet_code' => 'cabinet-1')
    end

    it 'is refused when its specialist is not mapped' do
      reason = refusal_reason { service.import_reported_reception!(detail('reception-9', 'SPECIALIST_CODE' => 'left-the-clinic')) }

      expect(reason).to eq(:specialist_not_mapped)
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
      expect(appointment.custom_attributes['provider_status_audit']).to eq(no_show_audit)
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
  end

  describe 'a detail that does not say whether the reception is active' do
    let(:local_cancellation) do
      { 'at' => '2026-10-08T05:00:00Z', 'reception_code' => 'reception-1', 'provider_starts_at' => '2026-10-07T05:00:00Z',
        'previous_status' => 'scheduled', 'previous_payment_status' => 'awaiting_payment' }
    end
    let(:preserved_audit) do
      { 'source' => 'medelement_reception_sync', 'previous_status' => 'scheduled', 'status' => 'cancelled',
        'reason' => 'preserved_local_cancellation', 'observed_at' => '2026-10-08T05:10:00Z' }
    end
    let(:unknown) { [{ 'ACTIVE' => nil }, { 'ACTIVE' => '' }, { 'ACTIVE' => '  ' }, {}] }

    # nil, blank and missing: the detail is the same for the importer, which is given the keys it was given.
    def unknown_detail(code, variant)
      variant.empty? ? detail(code).except('ACTIVE') : detail(code, **variant)
    end

    it 'does not complete an appointment, whatever the unknown looks like' do
      unknown.each_with_index do |variant, index|
        open = existing_appointment("open-#{index}", status: 'confirmed')
        scheduled = existing_appointment("scheduled-#{index}")

        service.import_reported_reception!(unknown_detail("open-#{index}", variant))
        service.import_reported_reception!(unknown_detail("scheduled-#{index}", variant))

        expect([open, scheduled].map { |appointment| appointment.reload.status }).to eq(%w[confirmed scheduled])
      end
    end

    it 'does not reopen a completed appointment either, and keeps what said so' do
      audit = { 'source' => 'medelement_reception_sync', 'previous_status' => 'scheduled', 'status' => 'completed',
                'reason' => 'provider_inactive', 'observed_at' => '2026-10-07T12:00:00Z' }
      completed = existing_appointment(status: 'completed', custom_attributes: { 'provider_status_audit' => audit })

      service.import_reported_reception!(detail('reception-1', 'ACTIVE' => nil))

      expect(completed.reload.status).to eq('completed')
      expect(completed.custom_attributes['provider_status_audit']).to eq(audit)
    end

    it 'imports a new reception as scheduled, not as completed' do
      unknown.each_with_index do |variant, index|
        service.import_reported_reception!(unknown_detail("new-#{index}", variant))

        expect(imported("new-#{index}")).to have_attributes(status: 'scheduled')
        expect(imported("new-#{index}").custom_attributes['provider_status_audit']).to include('reason' => 'provider_activity_unknown')
      end
    end

    it 'still completes what the detail says is not active' do
      closed = existing_appointment('closed-1')
      numeric_string = existing_appointment('closed-2')

      service.import_reported_reception!(detail('closed-1', 'ACTIVE' => 0))
      service.import_reported_reception!(detail('closed-2', 'ACTIVE' => '0'))

      expect([closed, numeric_string].map { |appointment| appointment.reload.status }).to eq(%w[completed completed])
    end

    context 'with patient sync on and a local cancellation that MedElement still holds' do
      let!(:cancelled) do
        existing_appointment(
          status: 'cancelled', payment_status: 'cancelled',
          custom_attributes: { 'medelement_local_cancellation' => local_cancellation, 'provider_status_audit' => preserved_audit }
        )
      end

      before do
        hook.update!(settings: hook.settings.merge('sync_patients' => true))
        allow(client).to receive(:get_patient).with(patient_code: 'patient-1').and_return(
          'PROFILE_CODE' => 'patient-1', 'COMPANY_CODE' => hook.settings['organization_id'], 'FULLNAME' => 'Provider Patient',
          'LASTNAME' => 'Patient', 'IIN' => '720914402646'
        )
      end

      it 'keeps the cancellation marker, the status and the stored audit when ACTIVE is unknown' do
        unknown.each do |variant|
          service.import_reported_reception!(unknown_detail('reception-1', variant))

          expect(cancelled.reload).to have_attributes(status: 'cancelled', payment_status: 'cancelled')
          expect(cancelled.custom_attributes['medelement_local_cancellation']).to eq(local_cancellation)
          expect(cancelled.custom_attributes['provider_status_audit']).to eq(preserved_audit)
        end
      end

      it 'keeps it as before while the reception is reported active, and ends it when the reception is not active' do
        service.import_reported_reception!(detail)
        expect(cancelled.reload).to have_attributes(status: 'cancelled')
        expect(cancelled.custom_attributes['medelement_local_cancellation']).to eq(local_cancellation)
        expect(cancelled.custom_attributes['provider_status_audit']).to include('reason' => 'preserved_local_cancellation')

        service.import_reported_reception!(detail('reception-1', 'ACTIVE' => 0))
        expect(cancelled.reload.status).to eq('completed')
        expect(cancelled.custom_attributes).not_to have_key('medelement_local_cancellation')
      end

      it 'still imports the rest of the detail, such as the time the reception was moved to' do
        service.import_reported_reception!(detail('reception-1', 'ACTIVE' => nil, 'STARTTIME' => '2026-10-07 12:00:00',
                                                                 'ENDTIME' => '2026-10-07 12:20:00'))

        expect(cancelled.reload).to have_attributes(status: 'cancelled', starts_at: Time.utc(2026, 10, 7, 7, 0))
        expect(cancelled.custom_attributes['medelement_local_cancellation']).to eq(local_cancellation)
      end
    end
  end

  describe '#preview_reported_status' do
    it 'gives the status of the import for a detail without cabinet' do
      existing_appointment('closed-1')
      existing_appointment('open-1')

      expect(service.preview_reported_status(detail('closed-1', 'ACTIVE' => 0))).to eq('completed')
      expect(service.preview_reported_status(detail('open-1'))).to eq('scheduled')
    end

    it 'does not ask for the specialist or the cabinet of an appointment OneLink has' do
      existing_appointment('foreign-1')
      existing_appointment('stray-1', resource: single_cabinet_doctor)

      expect(service.preview_reported_status(detail('foreign-1', 'SPECIALIST_CODE' => 'left-the-clinic', 'ACTIVE' => 0))).to eq('completed')
      expect(service.preview_reported_status(detail('stray-1', 'SPECIALIST_CODE' => 'doctor-2', 'COMPANY_CABINET_CODE' => 'cabinet-1')))
        .to eq('scheduled')
    end

    it 'is absent without an appointment, and cancelled for a removed reception' do
      existing_appointment('removed-1')

      expect(service.preview_reported_status(detail('nobody-1'))).to eq(:absent)
      expect(service.preview_reported_status(detail('removed-1', 'REMOVED' => 1))).to eq('cancelled')
    end

    it 'keeps an earlier explicit outcome like the import does' do
      existing_appointment(
        status: 'no_show', custom_attributes: { 'provider_status_audit' => { 'status' => 'no_show', 'reason' => 'provider_explicit_no_show' } }
      )

      expect(service.preview_reported_status(detail)).to eq('no_show')
    end

    it 'does not complete an appointment for a detail without ACTIVE' do
      existing_appointment

      expect(service.preview_reported_status(detail.merge('ACTIVE' => nil))).to eq('scheduled')
      expect(service.preview_reported_status(detail.except('ACTIVE'))).to eq('scheduled')
    end

    it 'writes nothing' do
      appointment = existing_appointment

      expect { service.preview_reported_status(detail('reception-1', 'ACTIVE' => 0)) }.not_to(change { appointment.reload.attributes })
    end
  end

  describe '#apply_reported_status!' do
    let(:open_statuses) { Integrations::Medelement::StaleStatusReconciler::OPEN_STATUSES }

    it 'gives the appointment the status that #preview_reported_status gives it' do
      [['closed-1', { 'ACTIVE' => 0 }], ['no-show-1', { 'VISIT_STATUS_NAME' => 'неявка' }], ['open-1', {}],
       ['unknown-1', { 'ACTIVE' => nil }], ['removed-1', { 'REMOVED' => 1 }]].each do |code, overrides|
        existing_appointment(code)
        expected = service.preview_reported_status(detail(code, **overrides))

        service.apply_reported_status!(detail(code, **overrides))

        expect(imported(code).status).to eq(expected)
      end
    end

    it 'is absent when OneLink has no appointment, and creates none' do
      expect(service.apply_reported_status!(detail('nobody-1', 'ACTIVE' => 0))).to eq(:absent)
      expect(account.scheduling_appointments.where(external_ref: 'medelement:reception:nobody-1')).to be_empty
    end

    it 'changes the status with its audit and nothing else, and does not read the patient or the cabinet' do
      appointment = existing_appointment(service_amount: 12_000, custom_attributes: { 'medelement_cabinet_code' => 'cabinet-1' })
      before = appointment.reload.attributes.except('status', 'custom_attributes', 'updated_at')

      service.apply_reported_status!(
        detail('reception-1', 'ACTIVE' => 0, 'SPECIALIST_CODE' => 'doctor-2', 'STARTTIME' => '2026-10-07 15:00:00',
                              'SERVICES' => [{ 'NOMENCLATURE_CODE' => 'nomenclature-1', 'PRICE' => 99_000, 'QUANTITY' => 1 }])
      )

      expect(appointment.reload.attributes.except('status', 'custom_attributes', 'updated_at')).to eq(before)
      expect(appointment).to have_attributes(status: 'completed')
      expect(appointment.custom_attributes.keys).to contain_exactly('medelement_cabinet_code', 'provider_status_audit')
      expect(appointment.custom_attributes['provider_status_audit']).to include(
        'source' => 'medelement_reception_sync', 'previous_status' => 'scheduled', 'status' => 'completed', 'reason' => 'provider_inactive'
      )
    end

    it 'does not write an appointment whose status does not change' do
      appointment = existing_appointment
      updated_at = appointment.updated_at

      result = service.apply_reported_status!(detail)

      expect(result).to eq(appointment)
      expect(appointment.reload).to have_attributes(updated_at: updated_at, custom_attributes: {})
    end

    it 'does not touch the specialist, so that an unmapped one makes no difference' do
      appointment = existing_appointment

      service.apply_reported_status!(detail('reception-1', 'SPECIALIST_CODE' => 'left-the-clinic', 'ACTIVE' => 0))

      expect(appointment.reload).to have_attributes(status: 'completed', resource_id: single_cabinet_doctor.id)
    end

    it 'is not sent back to MedElement: the update event is marked as coming from the provider, whoever acts' do
      appointment = existing_appointment
      Current.executed_by = create(:user, account: account)
      events = []
      allow(Rails.configuration.dispatcher).to receive(:dispatch) { |event_name, _, data| events << [event_name, data] }

      service.apply_reported_status!(detail('reception-1', 'ACTIVE' => 0))

      updated = events.find { |event_name, _| event_name == Events::Types::APPOINTMENT_UPDATED }
      expect(updated.last).to include(appointment: appointment, medelement_provider_reconciled: true)
    ensure
      Current.reset
    end

    it 'gives :no_longer_open when the appointment does not have one of the statuses asked for when its row is locked' do
      cancelled = existing_appointment(status: 'cancelled')

      result = service.apply_reported_status!(detail('reception-1', 'ACTIVE' => 0), only_from: open_statuses)

      expect(result).to eq(:no_longer_open)
      expect(cancelled.reload.status).to eq('cancelled')
    end

    it 'takes a removed reception through the reconciler of removals, as a polled removal does' do
      appointment = existing_appointment
      reconciler = instance_double(Integrations::Medelement::MissingAppointmentReconciler, perform: true)
      allow(Integrations::Medelement::MissingAppointmentReconciler).to receive(:new).and_return(reconciler)

      service.apply_reported_status!({ 'RECEPTION_CODE' => 'reception-1', 'REMOVED' => 1 })

      expect(Integrations::Medelement::MissingAppointmentReconciler).to have_received(:new).with(
        appointment: appointment, snapshot_version: appointment.updated_at, provider_removal_confirmed: true
      )
    end

    it 'keeps a local cancellation that MedElement still holds when the detail does not say whether it is active' do
      marker = { 'at' => '2026-10-08T05:00:00Z', 'provider_starts_at' => '2026-10-07T05:00:00Z' }
      cancelled = existing_appointment(status: 'cancelled', custom_attributes: { 'medelement_local_cancellation' => marker })

      service.apply_reported_status!(detail('reception-1', 'ACTIVE' => nil))

      expect(cancelled.reload.status).to eq('cancelled')
      expect(cancelled.custom_attributes).to eq('medelement_local_cancellation' => marker)
    end
  end

  describe '#specialist_mapped?' do
    it 'says whether the specialist of the detail has a resource in OneLink, under either spelling of the key' do
      expect(service.specialist_mapped?(detail('reception-1', 'SPECIALIST_CODE' => 'doctor-2'))).to be(true)
      expect(service.specialist_mapped?({ 'specialistCode' => 'doctor-1' })).to be(true)
      expect(service.specialist_mapped?(detail('reception-1', 'SPECIALIST_CODE' => 'left-the-clinic'))).to be(false)
      expect(service.specialist_mapped?({})).to be(false)
    end
  end
end
