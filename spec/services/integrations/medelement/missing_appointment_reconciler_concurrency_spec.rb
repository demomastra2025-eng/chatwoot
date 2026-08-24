require 'rails_helper'
require 'timeout'

RSpec.describe Integrations::Medelement::MissingAppointmentReconciler do
  self.use_transactional_tests = false

  it 'rejects a stale snapshot after waiting for a concurrent row mutation' do
    records = create_race_records
    snapshot_version = records.fetch(:appointment).updated_at
    mutation_locked = Queue.new
    release_mutation = Queue.new
    reconciler_entered = Queue.new
    result = Queue.new

    observe_reconciler_lock(records.fetch(:appointment), reconciler_entered)
    mutation_worker = hold_concurrent_mutation(records, mutation_locked, release_mutation)
    Timeout.timeout(5) { mutation_locked.pop }
    reconciler_worker = run_reconciler(records.fetch(:appointment), snapshot_version, result)
    Timeout.timeout(5) { reconciler_entered.pop }
    release_mutation << true
    [mutation_worker, reconciler_worker].each { |worker| Timeout.timeout(5) { worker.join } }

    expect(result.pop).to eq(:stale_snapshot)
    expect(records.fetch(:appointment).reload).to have_attributes(
      client_comment: 'concurrent mutation',
      status: 'scheduled'
    )
    expect(records.fetch(:appointment).custom_attributes).not_to include(
      'medelement_missing_since',
      'medelement_missing_syncs',
      'medelement_removed_at'
    )
  ensure
    release_mutation << true if defined?(release_mutation) && release_mutation.empty?
    mutation_worker&.join
    reconciler_worker&.join
    cleanup_race_records(records) if defined?(records) && records
  end

  def create_race_records
    account = create(:account)
    resource = create(:scheduling_resource, account: account)
    contact = create(:contact, account: account)
    appointment = create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      contact: contact,
      source: 'medelement',
      external_ref: "medelement:reception:#{SecureRandom.random_number(10**18).to_s.rjust(18, '0')}"
    )

    {
      account: account,
      resource: resource,
      contact: contact,
      service: appointment.service,
      appointment: appointment
    }
  end

  def observe_reconciler_lock(appointment, reconciler_entered)
    allow(appointment).to receive(:with_lock).and_wrap_original do |method, *args, &block|
      reconciler_entered << true
      method.call(*args, &block)
    end
  end

  def hold_concurrent_mutation(records, mutation_locked, release_mutation)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Scheduling::Appointment.transaction do
          appointment = Scheduling::Appointment.lock.find(records.fetch(:appointment).id)
          mutation_locked << true
          release_mutation.pop
          appointment.update!(client_comment: 'concurrent mutation')
        end
      end
    end
  end

  def run_reconciler(appointment, snapshot_version, result)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        result << described_class.new(appointment: appointment, snapshot_version: snapshot_version).perform
      end
    rescue StandardError => e
      result << e
    end
  end

  def cleanup_race_records(records)
    records.fetch(:appointment).destroy! if records.fetch(:appointment).persisted?
    records.fetch(:service).destroy! if records.fetch(:service)&.persisted?
    records.fetch(:contact).destroy! if records.fetch(:contact).persisted?
    records.fetch(:resource).destroy! if records.fetch(:resource).persisted?
    records.fetch(:account).destroy! if records.fetch(:account).persisted?
  end
end
