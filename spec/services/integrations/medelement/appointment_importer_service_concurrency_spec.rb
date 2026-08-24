require 'rails_helper'
require 'timeout'

RSpec.describe Integrations::Medelement::AppointmentImporterService do
  self.use_transactional_tests = false

  it 'does not overwrite a local mutation committed after lookup and before the importer lock' do
    records = create_race_records
    mutation_locked = Queue.new
    release_mutation = Queue.new
    lookup_complete = Queue.new
    result = Queue.new

    observe_importer_lookup(records, lookup_complete)
    mutation_worker = hold_local_mutation(records, mutation_locked, release_mutation)
    Timeout.timeout(5) { mutation_locked.pop }
    importer_worker = run_importer(records, result)
    Timeout.timeout(5) { lookup_complete.pop }
    release_mutation << true
    [mutation_worker, importer_worker].each(&:join)

    expect(result.pop).to eq(:stale_snapshot)
    expect(records.fetch(:appointment).reload.status).to eq('cancelled')
  ensure
    release_mutation << true if defined?(release_mutation) && release_mutation.empty?
    mutation_worker&.join
    importer_worker&.join
    cleanup_race_records(records) if defined?(records)
  end

  def create_race_records
    account, resource, contact = create_race_dependencies
    reception_code = SecureRandom.random_number(10**18).to_s.rjust(18, '0')
    appointment = create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      contact: contact,
      source: 'medelement',
      external_ref: "medelement:reception:#{reception_code}"
    )

    {
      account: account,
      resource: resource,
      contact: contact,
      service: appointment.service,
      appointment: appointment,
      reception_code: reception_code
    }
  end

  def create_race_dependencies
    account = create(:account)
    [account, create(:scheduling_resource, account: account), create(:contact, account: account)]
  end

  def hold_local_mutation(records, mutation_locked, release_mutation)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Scheduling::Appointment.transaction do
          appointment = Scheduling::Appointment.find(records.fetch(:appointment).id)
          appointment.lock!
          mutation_locked << true
          release_mutation.pop
          appointment.update!(status: 'cancelled')
        end
      end
    end
  end

  def observe_importer_lookup(records, lookup_complete)
    association = records.fetch(:account).scheduling_appointments
    allow(association).to receive(:find_or_initialize_by).and_wrap_original do |method, *args|
      method.call(*args).tap { lookup_complete << true }
    end
  end

  def run_importer(records, result)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        importer_for(records).upsert!(
          resource: records.fetch(:resource),
          contact: records.fetch(:contact),
          reception: reception_for(records.fetch(:reception_code)),
          import_context: import_context(records.fetch(:appointment).updated_at)
        )
      end
      result << :imported
    rescue Integrations::Medelement::AppointmentSnapshotGuard::StaleSnapshotError
      result << :stale_snapshot
    rescue StandardError => e
      result << e
    end
  end

  def importer_for(records)
    described_class.new(account: records.fetch(:account))
  end

  def reception_for(reception_code)
    {
      'RECEPTION_CODE' => reception_code,
      'PATIENT_CODE' => 'patient-1',
      'STARTTIME' => '20.03.2026 10:00:00',
      'ENDTIME' => '20.03.2026 10:30:00',
      'ACTIVE' => 1,
      'REMOVED' => 0,
      'VISIT_STATUS' => 1,
      'SERVICES' => []
    }
  end

  def import_context(snapshot_updated_at)
    {
      starts_at: Time.zone.parse('2026-03-20 10:00:00'),
      ends_at: Time.zone.parse('2026-03-20 10:30:00'),
      specialist_code: 'specialist-1',
      snapshot_version: { exists: true, updated_at: snapshot_updated_at }
    }
  end

  def cleanup_race_records(records)
    records.fetch(:appointment).destroy! if records.fetch(:appointment).persisted?
    records.fetch(:service).destroy! if records.fetch(:service).persisted?
    records.fetch(:contact).destroy! if records.fetch(:contact).persisted?
    records.fetch(:resource).destroy! if records.fetch(:resource).persisted?
    records.fetch(:account).destroy! if records.fetch(:account).persisted?
  end
end
