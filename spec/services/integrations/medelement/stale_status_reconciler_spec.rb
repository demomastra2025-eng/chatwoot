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
    it 'completes a scheduled appointment through the importer and records where the status came from' do
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

      expect(lock).to have_received(:lock).with(run_key, described_class::RUN_LOCK_LEASE).once
      expect(lock).to have_received(:lock).with(sync_key, described_class::SYNC_LOCK_LEASE).twice
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

  describe 'receptions the import refuses' do
    it 'counts a reception of an unmapped specialist as out of scope and does not change the appointment' do
      appointment = stale_appointment('reception-1')
      provider_says(appointment, 'SPECIALIST_CODE' => 'left-the-clinic', 'ACTIVE' => 0)

      report = reconciler.perform

      expect(report).to have_attributes(out_of_scope: 1, changed: 0)
      expect(appointment.reload.status).to eq('scheduled')
    end

    it 'skips a reception whose rows the importer refuses and goes on' do
      broken = stale_appointment('broken-1')
      fine = stale_appointment('fine-1')
      provider_says(broken, 'SERVICES' => ['not a row'], 'ACTIVE' => 0)
      provider_says(fine, 'ACTIVE' => 0)

      report = reconciler.perform

      expect(report).to have_attributes(skipped: 1, changed: 1)
      expect(report.skipped_reasons).to eq('InvalidSnapshotError' => 1)
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

      expect(report).to have_attributes(dry_run: true, examined: 4, changed: 1, unchanged: 1, not_found: 1, out_of_scope: 1)
      expect(report.transitions).to eq('scheduled' => { 'completed' => 1 }, 'confirmed' => { 'confirmed' => 1 })
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

      expect(lines).to include('  scheduled -> completed: 1', '  confirmed -> confirmed: 1')
      expect(lines).to include(a_string_matching(/not found at MedElement.*#{gone.id}/))
      expect(lines).to include(a_string_matching(/out of scope.*: 1/))
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
      expect(lock).to have_received(:renew).with(run_key, described_class::RUN_LOCK_LEASE).exactly(3).times
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
      expect(sleeps.size).to eq(described_class::SYNC_LOCK_ATTEMPTS - 1)
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
