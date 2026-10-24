require 'rails_helper'

RSpec.describe Integrations::Medelement::StaleStatusReconciler do
  include ActiveSupport::Testing::TimeHelpers

  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:hook) do
    create(:integrations_hook, :medelement, account: account).tap do |record|
      record.update!(settings: record.settings.merge('sync_patients' => false))
    end
  end
  let(:client) { instance_double(Integrations::Medelement::Client) }
  let(:lock) { instance_double(Redis::LockManager, lock: true, unlock: true, renew: true) }
  let(:sleeps) { [] }
  let(:sleeper) { ->(seconds) { sleeps << seconds } }
  let(:provider) { {} }
  let(:run_key) { format(Redis::Alfred::MEDELEMENT_STALE_STATUS_MUTEX, hook_id: hook.id) }
  let(:sync_key) { format(Redis::Alfred::MEDELEMENT_SYNC_MUTEX, account_id: account.id) }
  let!(:resource) do
    create(:scheduling_resource, account: account, timezone: 'Asia/Almaty',
                                 custom_attributes: {
                                   'medelement_specialist_code' => 'doctor-1',
                                   'medelement_cabinets' => [{ 'company_cabinet_code' => 'cabinet-1' }]
                                 })
  end

  before do
    hook
    allow(Redis::LockManager).to receive(:new).and_return(lock)
    allow(client).to receive(:get_reception) do |reception_code:, **|
      answer = provider.fetch(reception_code) do
        raise Integrations::Medelement::Client::ApiError.new('not found', status: 404)
      end
      raise answer if answer.is_a?(Exception)

      answer
    end
  end

  def reconciler(**)
    described_class.new(hook: hook, client: client, sleeper: sleeper, **)
  end

  def stale_appointment(code, **attributes)
    starts_at = attributes.delete(:starts_at) || 3.days.ago.change(min: 0, sec: 0)
    create(:scheduling_appointment, account: account, resource: resource, source: 'medelement', status: 'scheduled',
                                    starts_at: starts_at, external_ref: "medelement:reception:#{code}", **attributes)
  end

  def detail_for(appointment, **overrides)
    zone = 'Asia/Almaty'
    {
      'RECEPTION_CODE' => appointment.external_ref.delete_prefix('medelement:reception:'),
      'PROFILE_CODE' => 'patient-1', 'PATIENT_CODE' => 'patient-1', 'COMPANY_CODE' => hook.settings['organization_id'],
      'SPECIALIST_CODE' => 'doctor-1', 'COMPANY_CABINET_CODE' => 'cabinet-1',
      'STARTTIME' => appointment.starts_at.in_time_zone(zone).strftime('%Y-%m-%d %H:%M:%S'),
      'ENDTIME' => appointment.ends_at.in_time_zone(zone).strftime('%Y-%m-%d %H:%M:%S'),
      'SERVICES' => [], 'ACTIVE' => 1, 'REMOVED' => 0
    }.merge(overrides)
  end

  def provider_says(appointment, **overrides)
    provider[appointment.external_ref.delete_prefix('medelement:reception:')] = detail_for(appointment, **overrides)
  end

  def database_writes(&)
    statements = []
    subscriber = lambda do |_name, _started, _finished, _id, payload|
      statements << payload[:sql] if payload[:sql].to_s.match?(/\A\s*(INSERT|UPDATE|DELETE)\b/i)
    end
    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record', &)
    statements
  end

  describe 'which appointments it reads' do
    let!(:scheduled) { stale_appointment('scheduled-1') }
    let!(:confirmed) { stale_appointment('confirmed-1', status: 'confirmed', starts_at: 10.days.ago) }

    before do
      stale_appointment('recent-1', starts_at: 12.hours.ago)
      stale_appointment('completed-1', status: 'completed')
      stale_appointment('cancelled-1', status: 'cancelled')
      stale_appointment('manual-1', source: 'manual')
      stale_appointment('no-prefix', external_ref: 'other:reception:no-prefix')
      create(:scheduling_appointment, account: account, resource: resource, source: 'medelement', external_ref: nil,
                                      starts_at: 3.days.ago)
      stale_appointment('old-1', starts_at: 45.days.ago)
      stale_appointment('other-account-1').update_columns(account_id: create(:account).id) # rubocop:disable Rails/SkipsModelValidations
      [scheduled, confirmed].each { |appointment| provider_says(appointment) }
      provider_says(account.scheduling_appointments.find_by!(external_ref: 'medelement:reception:old-1'))
    end

    it 'takes MedElement appointments that are scheduled or confirmed and started more than a day ago, 30 days back' do
      report = reconciler(dry_run: true).perform

      expect(report.examined).to eq(2)
      expect(client).to have_received(:get_reception).with(reception_code: 'scheduled-1', version: :v2)
      expect(client).to have_received(:get_reception).with(reception_code: 'confirmed-1', version: :v2)
      expect(client).to have_received(:get_reception).twice
    end

    it 'looks as far back as asked, and over the whole history with days nil' do
      expect(reconciler(dry_run: true, days: 7).perform.examined).to eq(1)
      expect(reconciler(dry_run: true, days: nil).perform.examined).to eq(3)
    end
  end

  describe 'the margin of a day' do
    it 'reads an appointment only once a full day has passed since its start' do
      early = stale_appointment('early-1', starts_at: 23.hours.ago)
      late = stale_appointment('late-1', starts_at: 25.hours.ago)
      [early, late].each { |appointment| provider_says(appointment) }

      report = reconciler(dry_run: true).perform

      expect(report.examined).to eq(1)
      expect(client).to have_received(:get_reception).with(reception_code: 'late-1', version: :v2)
    end
  end

  describe 'applying the provider status' do
    it 'completes a scheduled appointment with the status of the importer mapping and records where it came from' do
      appointment = stale_appointment('reception-1')
      provider_says(appointment, 'VISIT_STATUS_NAME' => 'завершена')

      report = reconciler.perform

      expect(report).to have_attributes(examined: 1, changed: 1, unchanged: 0, aborted: nil, remaining: 0)
      expect(report.transitions).to eq('scheduled' => { 'completed' => 1 })
      expect(appointment.reload.status).to eq('completed')
      expect(appointment.custom_attributes['provider_status_audit']).to include(
        'source' => 'medelement_reception_sync', 'previous_status' => 'scheduled', 'status' => 'completed',
        'reason' => 'provider_explicit_completed'
      )
    end

    it 'applies every kind of provider outcome with the importer mapping' do
      completed = stale_appointment('done-1')
      inactive = stale_appointment('inactive-1', status: 'confirmed')
      no_show = stale_appointment('no-show-1')
      cancelled = stale_appointment('cancelled-by-provider-1')
      removed = stale_appointment('removed-1')
      provider_says(completed, 'VISIT_STATUS_NAME' => 'завершена')
      provider_says(inactive, 'ACTIVE' => 0)
      provider_says(no_show, 'VISIT_STATUS_NAME' => 'неявка')
      provider_says(cancelled, 'VISIT_STATUS_NAME' => 'отменена')
      provider_says(removed, 'REMOVED' => 1)

      report = reconciler.perform

      expect(report.transitions).to eq(
        'scheduled' => { 'completed' => 1, 'no_show' => 1, 'cancelled' => 2 }, 'confirmed' => { 'completed' => 1 }
      )
      expect(report.changed).to eq(5)
      expect([completed, inactive, no_show, cancelled, removed].map { |appointment| appointment.reload.status })
        .to eq(%w[completed completed no_show cancelled cancelled])
    end

    it 'leaves an appointment that MedElement still shows as open, and reports it as unchanged' do
      scheduled = stale_appointment('open-1')
      confirmed = stale_appointment('open-2', status: 'confirmed')
      provider_says(scheduled)
      provider_says(confirmed)

      report = reconciler.perform

      expect(report).to have_attributes(changed: 0, unchanged: 2)
      expect(report.transitions).to eq('scheduled' => { 'scheduled' => 1 }, 'confirmed' => { 'confirmed' => 1 })
      expect([scheduled, confirmed].map { |appointment| appointment.reload.status }).to eq(%w[scheduled confirmed])
    end

    it 'does not read the appointment again once MedElement has closed it' do
      appointment = stale_appointment('reception-1')
      provider_says(appointment, 'ACTIVE' => 0)

      reconciler.perform
      second = reconciler.perform

      expect(second.examined).to eq(0)
      expect(client).to have_received(:get_reception).once
    end

    it 'takes the account sync lock for each import only, and the hook lock for the whole run' do
      2.times { |index| provider_says(stale_appointment("reception-#{index}"), 'ACTIVE' => 0) }

      reconciler.perform

      expect(lock).to have_received(:lock).with(run_key, Integrations::Medelement::StaleStatusLocks::RUN_LEASE).once
      expect(lock).to have_received(:lock).with(sync_key, Integrations::Medelement::StaleStatusLocks::SYNC_LEASE).twice
      expect(lock).to have_received(:unlock).with(sync_key).twice
      expect(lock).to have_received(:unlock).with(run_key).once
    end
  end

  describe 'a reception that MedElement does not have' do
    it 'reports it and keeps the appointment untouched' do
      appointment = stale_appointment('gone-1')
      updated_at = appointment.updated_at

      report = reconciler.perform

      expect(report).to have_attributes(examined: 1, not_found: 1, changed: 0, not_found_appointment_ids: [appointment.id])
      expect(report.transitions).to be_empty
      expect(appointment.reload).to have_attributes(status: 'scheduled', updated_at: updated_at)
    end

    it 'treats an empty answer and an answer for another reception the same way' do
      empty = stale_appointment('empty-1')
      other = stale_appointment('other-1')
      provider['empty-1'] = nil
      provider['other-1'] = detail_for(other, 'RECEPTION_CODE' => 'someone-else')

      report = reconciler.perform

      expect(report.not_found_appointment_ids).to contain_exactly(empty.id, other.id)
      expect(Scheduling::Appointment.where(id: [empty.id, other.id]).pluck(:status)).to eq(%w[scheduled scheduled])
    end

    it 'goes on with the other appointments and does not count it as a provider failure' do
      gone = stale_appointment('gone-1')
      found = stale_appointment('found-1')
      provider_says(found, 'ACTIVE' => 0)

      report = reconciler.perform

      expect(report).to have_attributes(not_found: 1, changed: 1, errors: 0, aborted: nil)
      expect(found.reload.status).to eq('completed')
      expect(gone.reload.status).to eq('scheduled')
    end

    it 'reports it in a dry run too' do
      appointment = stale_appointment('gone-1')

      report = reconciler(dry_run: true).perform

      expect(report.not_found_appointment_ids).to eq([appointment.id])
    end
  end

  describe 'receptions the status does not depend on' do
    it 'applies the status of an appointment whose detail names a specialist OneLink does not know, and counts the detail' do
      appointment = stale_appointment('reception-1')
      provider_says(appointment, 'SPECIALIST_CODE' => 'left-the-clinic', 'ACTIVE' => 0)

      dry = reconciler(dry_run: true).perform
      real = reconciler.perform

      expect(dry).to have_attributes(unmapped_specialist: 1, changed: 1)
      expect(real).to have_attributes(unmapped_specialist: 1, changed: 1, skipped: 0)
      expect(appointment.reload).to have_attributes(status: 'completed', resource_id: resource.id)
    end

    it 'counts nothing for a specialist OneLink knows' do
      provider_says(stale_appointment('reception-1'), 'ACTIVE' => 0)

      expect(reconciler.perform).to have_attributes(unmapped_specialist: 0, changed: 1)
    end

    it 'skips an appointment that cannot be saved, and goes on' do
      broken = stale_appointment('broken-1')
      fine = stale_appointment('fine-1')
      broken.update_columns(client_name: '') # rubocop:disable Rails/SkipsModelValidations
      provider_says(broken, 'ACTIVE' => 0)
      provider_says(fine, 'ACTIVE' => 0)

      report = reconciler.perform

      expect(report).to have_attributes(skipped: 1, changed: 1)
      expect(report.skipped_reasons).to eq('RecordInvalid' => 1)
      expect([broken, fine].map { |appointment| appointment.reload.status }).to eq(%w[scheduled completed])
    end

    it 'skips an appointment that was changed by someone else before the import' do
      appointment = stale_appointment('reception-1')
      provider_says(appointment, 'ACTIVE' => 0)
      allow(client).to receive(:get_reception) do |**|
        appointment.update!(status: 'cancelled')
        detail_for(appointment, 'ACTIVE' => 0)
      end

      report = reconciler.perform

      expect(report).to have_attributes(skipped: 1, changed: 0)
      expect(report.skipped_reasons).to eq('no_longer_open' => 1)
    end
  end

  describe 'a detail that does not say whether the reception is active' do
    # nil, blank and a missing ACTIVE are unknown, never "not active": the appointment is not completed, and nothing is written.
    let!(:appointments) do
      { nil: stale_appointment('nil-1'), blank: stale_appointment('blank-1', status: 'confirmed'), missing: stale_appointment('missing-1') }
    end

    before do
      provider_says(appointments[:nil], 'ACTIVE' => nil)
      provider_says(appointments[:blank], 'ACTIVE' => ' ')
      provider['missing-1'] = detail_for(appointments[:missing]).except('ACTIVE')
    end

    it 'does not complete the appointment, in a dry run or in a real run, and writes nothing' do
      updated = Scheduling::Appointment.order(:id).pluck(:id, :status, :updated_at, :custom_attributes)
      dry = reconciler(dry_run: true).perform
      real = nil
      writes = database_writes { real = reconciler.perform }

      expect(dry.transitions).to eq('scheduled' => { 'scheduled' => 2 }, 'confirmed' => { 'confirmed' => 1 })
      expect(real.transitions).to eq(dry.transitions)
      expect(real).to have_attributes(examined: 3, changed: 0, unchanged: 3, skipped: 0)
      expect(writes).to be_empty
      expect(Scheduling::Appointment.order(:id).pluck(:id, :status, :updated_at, :custom_attributes)).to eq(updated)
    end

    it 'still completes an appointment whose detail says it is not active' do
      closed = stale_appointment('closed-1')
      numeric_string = stale_appointment('closed-2')
      provider_says(closed, 'ACTIVE' => 0)
      provider_says(numeric_string, 'ACTIVE' => '0')

      reconciler.perform

      expect([closed, numeric_string].map { |appointment| appointment.reload.status }).to eq(%w[completed completed])
      expect(appointments.values.map { |appointment| appointment.reload.status }).to eq(%w[scheduled confirmed scheduled])
    end
  end

  describe 'details without a cabinet, as MedElement gives them' do
    # single: the doctor with one cabinet. bare: the same, with no cabinet stored. multi: a doctor with two cabinets. stray: an
    # appointment of the first doctor that MedElement now gives to the second. foreign: an unmapped doctor. wrong: an appointment
    # of the first doctor that MedElement gives to the second, with a cabinet the second doctor does not have. renamed: the doctor's
    # own appointment, for which the detail names another cabinet (the cabinet of a created reception never changes).
    let!(:appointments) do
      two_cabinets = create(:scheduling_resource, account: account, timezone: 'Asia/Almaty',
                                                  custom_attributes: { 'medelement_specialist_code' => 'doctor-2',
                                                                       'medelement_cabinets' => [{ 'company_cabinet_code' => 'cabinet-2' },
                                                                                                 { 'company_cabinet_code' => 'cabinet-3' }] })
      {
        single: stale_appointment('single-1', custom_attributes: { 'medelement_cabinet_code' => 'cabinet-1' }),
        bare: stale_appointment('bare-1'),
        multi: stale_appointment('multi-1', resource: two_cabinets, status: 'confirmed',
                                            custom_attributes: { 'medelement_cabinet_code' => 'cabinet-3' }, service_amount: 12_000,
                                            prepaid_amount: 2000, payment_status: 'prepaid'),
        stray: stale_appointment('stray-1', custom_attributes: { 'medelement_cabinet_code' => 'cabinet-1' }),
        foreign: stale_appointment('foreign-1'),
        wrong: stale_appointment('wrong-1', custom_attributes: { 'medelement_cabinet_code' => 'cabinet-1' }),
        renamed: stale_appointment('renamed-1', custom_attributes: { 'medelement_cabinet_code' => 'cabinet-1' })
      }
    end

    before do
      provider_says(appointments[:single], 'COMPANY_CABINET_CODE' => nil, 'ACTIVE' => 0)
      provider_says(appointments[:bare], 'COMPANY_CABINET_CODE' => nil, 'VISIT_STATUS_NAME' => 'неявка')
      provider_says(appointments[:multi], 'COMPANY_CABINET_CODE' => nil, 'SPECIALIST_CODE' => 'doctor-2', 'ACTIVE' => 0)
      provider_says(appointments[:stray], 'COMPANY_CABINET_CODE' => nil, 'SPECIALIST_CODE' => 'doctor-2', 'ACTIVE' => 0)
      provider_says(appointments[:foreign], 'COMPANY_CABINET_CODE' => nil, 'SPECIALIST_CODE' => 'left-the-clinic', 'ACTIVE' => 0)
      provider_says(appointments[:wrong], 'SPECIALIST_CODE' => 'doctor-2', 'COMPANY_CABINET_CODE' => 'cabinet-1', 'ACTIVE' => 0)
      provider_says(appointments[:renamed], 'COMPANY_CABINET_CODE' => 'cabinet-3', 'ACTIVE' => 0)
    end

    it 'applies the status of each of them, and a dry run and the real run follow the same rule' do
      dry = reconciler(dry_run: true).perform
      real = reconciler.perform

      expect(dry.transitions).to eq('scheduled' => { 'completed' => 5, 'no_show' => 1 }, 'confirmed' => { 'completed' => 1 })
      expect(real.transitions).to eq(dry.transitions)
      expect([real.changed, real.unchanged, real.skipped]).to eq([dry.changed, dry.unchanged, dry.skipped]).and eq([7, 0, 0])
      expect([real.unmapped_specialist, dry.unmapped_specialist]).to eq([1, 1])
      expect(appointments.values.map { |appointment| appointment.reload.status })
        .to eq(%w[completed no_show completed completed completed completed completed])
    end

    it 'keeps the resource, the payment and the cabinet of an appointment it closes' do
      reconciler.perform

      multi = appointments[:multi].reload
      expect(multi).to have_attributes(status: 'completed', service_amount: 12_000, prepaid_amount: 2000, payment_status: 'prepaid')
      expect(multi.custom_attributes).to include('medelement_cabinet_code' => 'cabinet-3')
      expect(appointments[:single].reload.custom_attributes).to include('medelement_cabinet_code' => 'cabinet-1')
      expect(appointments[:bare].reload.custom_attributes).not_to have_key('medelement_cabinet_code')
      expect(appointments[:renamed].reload.custom_attributes).to include('medelement_cabinet_code' => 'cabinet-1')
      # MedElement names another specialist for these two, and the status is all that is taken from it.
      expect([appointments[:stray], appointments[:wrong]].map { |appointment| appointment.reload.resource_id }).to eq([resource.id] * 2)
      expect([appointments[:stray], appointments[:wrong]].map { |appointment| appointment.custom_attributes['medelement_cabinet_code'] })
        .to eq(%w[cabinet-1 cabinet-1])
    end

    it 'reports the detail of the unmapped specialist in the summary' do
      lines = reconciler(dry_run: true).perform.summary_lines

      expect(lines).to include(a_string_matching(/not mapped in OneLink.*all the same\): 1\z/))
    end
  end

  describe 'what a status change leaves alone, with patient sync on' do
    let(:hook) do
      create(:integrations_hook, :medelement, account: account).tap do |record|
        record.update!(settings: record.settings.merge('sync_patients' => true))
      end
    end
    let!(:appointment) do
      patient = create(:contact, account: account, name: 'Local', last_name: 'Patient', phone_number: '+77015235543',
                                 identifier: '720914402646', custom_attributes: { 'medelement_patient_code' => 'patient-1' })
      consultation = create(:scheduling_service, account: account, name: 'Consultation', base_price: 15_000,
                                                 custom_attributes: { 'medelement_nomenclature_code' => 'nomenclature-1' })
      stale_appointment(
        'rich-1', contact: patient, patient_contact: patient, service: consultation, status: 'confirmed',
                  client_first_name: 'Local', client_last_name: 'Patient', client_name: 'Local Patient', client_phone: '+77015235543',
                  client_identifier: '720914402646', client_birth_date: Date.new(1990, 5, 17), client_gender: 'female',
                  service_amount: 15_000, prepaid_amount: 5000, payment_status: 'prepaid',
                  custom_attributes: { 'medelement_cabinet_code' => 'cabinet-1', 'medelement_reception_code' => 'rich-1',
                                       'medelement_patient_code' => 'patient-1', 'medelement_specialist_code' => 'doctor-1',
                                       'medelement_list_fingerprint' => 'fingerprint', 'medelement_detail_synced_at' => '2026-09-01T10:00:00Z',
                                       'medelement_missing_since' => '2026-09-02T10:00:00Z', 'medelement_missing_syncs' => 1,
                                       'provider_status_audit' => { 'source' => 'medelement_reception_sync', 'status' => 'confirmed',
                                                                    'reason' => 'preserved_local_confirmation' } }
      )
    end
    # Everything a full import of this detail would rewrite: the patient, services, times, specialist and amounts.
    let(:detail) do
      detail_for(
        appointment, 'ACTIVE' => 0, 'COMPANY_CABINET_CODE' => nil, 'SPECIALIST_CODE' => 'doctor-2', 'PATIENT_FULLNAME' => 'Renamed Provider Patient',
                     'STARTTIME' => '2026-09-01 14:00:00', 'ENDTIME' => '2026-09-01 14:45:00',
                     'SERVICES' => [{ 'NOMENCLATURE_CODE' => 'nomenclature-1', 'PRICE' => 99_000, 'QUANTITY' => 2 }]
      )
    end

    def reconciliation_keys
      Integrations::Medelement::AppointmentImporterService::RECONCILIATION_ATTRIBUTE_KEYS
    end

    def everything_but_the_status
      record = Scheduling::Appointment.find(appointment.id)
      {
        columns: record.attributes.except('status', 'custom_attributes', 'updated_at'),
        custom_attributes: record.custom_attributes.except('provider_status_audit', *reconciliation_keys),
        payments: record.payments.map(&:attributes),
        contacts: account.contacts.order(:id).map(&:attributes),
        services: account.scheduling_services.order(:id).map(&:attributes),
        resources: account.scheduling_resources.order(:id).map(&:attributes)
      }
    end

    before do
      create(:scheduling_resource, account: account, timezone: 'Asia/Almaty',
                                   custom_attributes: { 'medelement_specialist_code' => 'doctor-2',
                                                        'medelement_cabinets' => [{ 'company_cabinet_code' => 'cabinet-2' }] })
      create(:scheduling_payment, appointment: appointment, amount: 5000, payment_method: 'cash')
      appointment.reload
      allow(client).to receive(:get_patient).and_return(
        'PROFILE_CODE' => 'patient-1', 'COMPANY_CODE' => hook.settings['organization_id'], 'FULLNAME' => 'Renamed Provider Patient',
        'LASTNAME' => 'Provider', 'IIN' => '720914402646', 'PATIENT_PHONE_2_STR' => '+7 777 1112233'
      )
      provider[appointment.external_ref.delete_prefix('medelement:reception:')] = detail
    end

    it 'changes the status and the audit of the status, and nothing else of the appointment, the patient or the payments' do
      before = everything_but_the_status

      report = reconciler.perform

      expect(report).to have_attributes(changed: 1, skipped: 0, unmapped_specialist: 0)
      expect(appointment.reload.status).to eq('completed')
      expect(appointment.custom_attributes['provider_status_audit']).to include(
        'source' => 'medelement_reception_sync', 'previous_status' => 'confirmed', 'status' => 'completed', 'reason' => 'provider_inactive'
      )
      expect(appointment.custom_attributes.keys).not_to include(*reconciliation_keys)
      expect(everything_but_the_status).to eq(before)
    end

    it 'does not read the patient or write anything to MedElement' do
      reconciler.perform

      expect(client).not_to have_received(:get_patient)
      expect(client).to have_received(:get_reception).once
    end

    it 'writes the appointment once, and its status is what changed' do
      writes = database_writes { reconciler.perform }

      expect(writes.grep(/\A\s*UPDATE "scheduling_appointments"/).size).to eq(1)
      expect(writes.grep(/\A\s*(INSERT|UPDATE|DELETE)/).grep_v(/scheduling_appointments/)).to be_empty
    end

    it 'leaves the appointment untouched in a dry run' do
      before = Scheduling::Appointment.find(appointment.id).attributes

      writes = database_writes { reconciler(dry_run: true).perform }

      expect(writes).to be_empty
      expect(Scheduling::Appointment.find(appointment.id).attributes).to eq(before)
      expect(client).not_to have_received(:get_patient)
    end
  end

  describe 'a dry run' do
    let!(:completed) { stale_appointment('done-1') }
    let!(:still_open) { stale_appointment('open-1', status: 'confirmed') }
    let!(:gone) { stale_appointment('gone-1') }
    let!(:foreign) { stale_appointment('foreign-1') }

    before do
      provider_says(completed, 'VISIT_STATUS_NAME' => 'завершена')
      provider_says(still_open)
      provider_says(foreign, 'SPECIALIST_CODE' => 'left-the-clinic')
    end

    it 'reports the old and the provider status of each appointment' do
      report = reconciler(dry_run: true).perform

      expect(report).to have_attributes(dry_run: true, examined: 4, changed: 1, unchanged: 2, not_found: 1, unmapped_specialist: 1)
      expect(report.transitions).to eq('scheduled' => { 'completed' => 1, 'scheduled' => 1 }, 'confirmed' => { 'confirmed' => 1 })
      expect(report.not_found_appointment_ids).to eq([gone.id])
    end

    it 'writes nothing and takes no lock' do
      before = Scheduling::Appointment.order(:id).pluck(:id, :status, :updated_at, :custom_attributes)
      tables_before = [Integrations::Medelement::SyncConflict.count, Contact.count]

      writes = database_writes { reconciler(dry_run: true).perform }

      expect(writes).to be_empty
      expect(Scheduling::Appointment.order(:id).pluck(:id, :status, :updated_at, :custom_attributes)).to eq(before)
      expect([Integrations::Medelement::SyncConflict.count, Contact.count]).to eq(tables_before)
      expect(Redis::LockManager).not_to have_received(:new)
    end

    it 'prints one line per transition and the outcomes without one' do
      lines = reconciler(dry_run: true).perform.summary_lines

      expect(lines).to include('  scheduled -> completed: 1', '  confirmed -> confirmed: 1', '  scheduled -> scheduled: 1')
      expect(lines).to include(a_string_matching(/not found at MedElement.*#{gone.id}/))
      expect(lines).to include(a_string_matching(/specialist that is not mapped in OneLink.*: 1\z/))
    end
  end

  describe 'patient-facing side effects' do
    include ActiveJob::TestHelper

    let!(:appointment) { stale_appointment('reception-1') }
    let(:webhook_url) { 'https://example.com/hooks/appointments' }

    def automation_rule(event_name)
      create(:automation_rule, account: account, event_name: event_name,
                               conditions: [{ attribute_key: 'status', filter_operator: 'equal_to', values: ['completed'], query_operator: nil }],
                               actions: [{ action_name: 'send_webhook_event', action_params: [webhook_url] }])
    end

    before do
      automation_rule('appointment_completed')
      provider_says(appointment, 'ACTIVE' => 0)
      clear_enqueued_jobs
    end

    it 'applies the status as a data correction: no event, automation rule or CRM job' do
      reconciler.perform
      perform_enqueued_jobs(only: EventDispatcherJob)

      expect(appointment.reload.status).to eq('completed')
      expect(EventDispatcherJob).not_to have_been_enqueued
      expect(WebhookJob).not_to have_been_enqueued
      expect(Crm::Appointments::AppointmentChangedJob).not_to have_been_enqueued
    end

    it 'still fires them for the same status change when the normal delta apply makes it' do
      delta = Integrations::Medelement::ReceptionsDeltaService.new(hook: hook, client: client)

      delta.apply_detail!(detail_for(appointment, 'ACTIVE' => 0))
      perform_enqueued_jobs(only: EventDispatcherJob)

      expect(appointment.reload.status).to eq('completed')
      expect(WebhookJob).to have_been_enqueued
      expect(Crm::Appointments::AppointmentChangedJob).to have_been_enqueued
    end

    it 'keeps an appointment that MedElement still shows as open quiet too' do
      open_one = stale_appointment('open-1')
      provider_says(open_one)
      clear_enqueued_jobs

      reconciler.perform

      expect(EventDispatcherJob).not_to have_been_enqueued
    end

    it 'leaves the flag off after a run, also when a status is refused', :aggregate_failures do
      broken = stale_appointment('broken-1')
      broken.update_columns(client_name: '') # rubocop:disable Rails/SkipsModelValidations
      provider_says(broken, 'ACTIVE' => 0)

      expect(reconciler.perform.skipped).to eq(1)
      expect(Current.medelement_reconciliation).to be_nil
    end

    describe 'the automation line of the report' do
      let(:no_show) { stale_appointment('no-show-1') }

      before do
        provider_says(no_show, 'VISIT_STATUS_NAME' => 'неявка')
        clear_enqueued_jobs
      end

      it 'tells in a dry run how many changes active rules would have reacted to, and fires nothing', :aggregate_failures do
        report = reconciler(dry_run: true).perform

        expect(report).to have_attributes(changed: 2, automation_matches: 1, automation_rules: { 'appointment_completed' => 1 })
        expect(report.summary_lines).to include(
          a_string_matching(/automation rules that would have triggered: 1 of 2 status changes.*appointment_completed/)
        )
        expect(EventDispatcherJob).not_to have_been_enqueued
        expect(WebhookJob).not_to have_been_enqueued
      end

      it 'counts every change for an appointment_updated rule' do
        automation_rule('appointment_updated')

        report = reconciler(dry_run: true).perform

        expect(report).to have_attributes(changed: 2, automation_matches: 2)
      end

      it 'says in a real run that the rules were held back' do
        report = reconciler.perform

        expect(report.summary_lines).to include(a_string_matching(/automation rules that held back \(not triggered\): 1 of 2/))
        expect(WebhookJob).not_to have_been_enqueued
      end

      it 'has no automation line when nothing changes' do
        open_one = stale_appointment('open-1')
        provider_says(open_one)
        provider.delete('reception-1')
        provider.delete('no-show-1')

        report = reconciler(dry_run: true).perform

        expect(report.summary_lines.grep(/automation/)).to be_empty
      end
    end
  end

  describe 'throttling, batches and the cap' do
    before do
      hook.update!(settings: hook.settings.merge('throttle_ms' => 500))
      5.times { |index| provider_says(stale_appointment("reception-#{index}")) }
    end

    it 'waits the configured throttle between two reads of the provider' do
      reconciler(dry_run: true).perform

      expect(sleeps).to eq([0.5] * 4)
    end

    it 'works through the appointments in batches and renews its lock after each' do
      report = reconciler(batch_size: 2).perform

      expect(report.examined).to eq(5)
      expect(lock).to have_received(:renew).with(run_key, Integrations::Medelement::StaleStatusLocks::RUN_LEASE).exactly(3).times
    end

    it 'stops at the cap of one run, says what is left, and the next run continues' do
      codes = []
      allow(client).to receive(:get_reception) do |reception_code:, **|
        codes << reception_code
        detail_for(account.scheduling_appointments.find_by!(external_ref: "medelement:reception:#{reception_code}"), 'ACTIVE' => 0)
      end

      first = reconciler(max_per_run: 2, batch_size: 50).perform
      expect(first).to have_attributes(examined: 2, remaining: 3, aborted: nil)

      second = reconciler(max_per_run: 2).perform
      third = reconciler(max_per_run: 2).perform
      expect([second.examined, third.examined]).to eq([2, 1])
      expect(third.remaining).to eq(0)
      expect(codes).to eq(%w[reception-4 reception-3 reception-2 reception-1 reception-0])
      expect(Scheduling::Appointment.distinct.pluck(:status)).to eq(['completed'])
    end

    it 'has no cap when asked for none' do
      expect(reconciler(dry_run: true, max_per_run: nil).perform).to have_attributes(examined: 5, remaining: 0)
    end

    it 'carries a default cap and a default window' do
      expect([described_class::DEFAULT_MAX_PER_RUN, described_class::DEFAULT_DAYS]).to eq([1000, 30])
    end
  end

  describe 'when the provider or the sync gets in the way' do
    it 'goes on after a single failed read and gives the provider a moment' do
      failing = stale_appointment('failing-1')
      fine = stale_appointment('fine-1')
      provider['failing-1'] = Integrations::Medelement::Client::ApiError.new('down', status: 503)
      provider_says(fine, 'ACTIVE' => 0)

      report = reconciler.perform

      expect(report).to have_attributes(errors: 1, changed: 1, aborted: nil)
      expect(report.error_codes).to eq('http_503' => 1)
      expect(failing.reload.status).to eq('scheduled')
      expect(sleeps).to include(described_class::PROVIDER_ERROR_PAUSE_SECONDS)
    end

    it 'stops after repeated consecutive failures and leaves the rest for the next run' do
      7.times { |index| provider["reception-#{index}"] = Integrations::Medelement::Client::ApiError.new('down', status: 503) }
      7.times { |index| stale_appointment("reception-#{index}") }

      report = reconciler.perform

      expect(report).to have_attributes(examined: 5, errors: 5, aborted: 'provider_errors', remaining: 2)
      expect(Scheduling::Appointment.distinct.pluck(:status)).to eq(['scheduled'])
    end

    it 'ends the run, writing nothing, when the account sync stays locked' do
      appointment = stale_appointment('reception-1')
      provider_says(appointment, 'ACTIVE' => 0)
      allow(lock).to receive(:lock) { |key, _lease| key != sync_key }

      report = reconciler.perform

      expect(report).to have_attributes(aborted: 'sync_busy', changed: 0)
      expect(sleeps.size).to eq(Integrations::Medelement::StaleStatusLocks::SYNC_ATTEMPTS - 1)
      expect(appointment.reload.status).to eq('scheduled')
      expect(lock).to have_received(:unlock).with(run_key)
    end

    it 'does not start while another run of the same hook is active' do
      stale_appointment('reception-1')
      allow(lock).to receive(:lock).with(run_key, anything).and_return(false)

      report = reconciler.perform

      expect(report).to have_attributes(aborted: 'already_running', examined: 0)
      expect(client).not_to have_received(:get_reception)
    end

    it 'ends the run when it has lost its hook lock' do
      2.times { |index| provider_says(stale_appointment("reception-#{index}")) }
      allow(lock).to receive(:renew).and_return(false)

      report = reconciler(batch_size: 1).perform

      expect(report).to have_attributes(aborted: 'lock_lost', examined: 1)
    end

    it 'does nothing for a hook that is disabled or does not sync receptions' do
      stale_appointment('reception-1')
      hook.update!(settings: hook.settings.merge('sync_receptions' => false))

      expect(reconciler.perform.aborted).to eq('not_eligible')
      hook.update!(settings: hook.settings.merge('sync_receptions' => true), status: 'disabled')
      expect(reconciler.perform.aborted).to eq('not_eligible')
      expect(client).not_to have_received(:get_reception)
    end
  end

  it 'reads the receptions with the short retry profile' do
    allow(Integrations::Medelement::Client).to receive(:new).and_return(client)

    described_class.new(hook: hook).perform

    expect(Integrations::Medelement::Client).to have_received(:new).with(
      configuration: an_instance_of(Integrations::Medelement::Configuration), retry_profile: :command
    )
  end
end
