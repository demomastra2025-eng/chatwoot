require 'rails_helper'
require 'timeout'

RSpec.describe Contacts::ReferenceMergeService do
  self.use_transactional_tests = false

  it 'waits for a provider write fence and refuses to re-point the patient card it just captured' do
    records = create_race_records
    fence_locked = Queue.new
    release_fence = Queue.new
    merge_backend = Queue.new
    outcome = Queue.new

    fence = hold_provider_write_fence(records, fence_locked, release_fence)
    Timeout.timeout(10) { fence_locked.pop }
    merge = run_operator_merge(records, merge_backend, outcome)
    wait_for_lock_wait(Timeout.timeout(10) { merge_backend.pop })
    release_fence << true
    [fence, merge].each { |worker| Timeout.timeout(10) { worker.join } }

    expect(outcome.pop).to be_a(described_class::UnsafeMergeError)
    expect(records.fetch(:appointment).reload.patient_contact_id).to eq(records.fetch(:card).id)
    expect(Contact.exists?(records.fetch(:card).id)).to be(true)
    expect(Integrations::Medelement::AppointmentPatientIdentity.current?(records.fetch(:command).reload)).to be(true)
  ensure
    release_fence << true if defined?(release_fence) && release_fence && release_fence.num_waiting.positive?
    fence&.join(10)
    merge&.join(10)
    cleanup_race_records(records) if defined?(records) && records
  end

  def create_race_records
    policy = Integrations::Medelement::AppointmentPatientIdentity
    account = create(:account)
    resource = create(:scheduling_resource, account: account)
    owner = create(:contact, account: account, name: 'Primary', phone_number: '+77000000001')
    card = create(:contact, account: account, name: 'Relative', last_name: 'Patient', phone_number: nil,
                            custom_attributes: { Integrations::Medelement::PatientContactBinding::CARD_KEY => true, 'iin' => '940720300129' })
    duplicate = create(:contact, account: account, name: 'Relative', phone_number: nil, identifier: '940720300129')
    appointment = create(:scheduling_appointment, account: account, resource: resource, contact: owner, patient_contact: card, service: nil,
                                                  client_name: 'Relative Patient', client_first_name: 'Relative', client_last_name: 'Patient',
                                                  client_identifier: '940720300129', client_phone: owner.phone_number,
                                                  custom_attributes: { policy::OWNED_IDENTITY_KEY => true, policy::EXPLICIT_IDENTIFIER_KEY => true })
    command = Integrations::Medelement::ProviderCommand.new(
      account: account, appointment: appointment, contact: owner, operation: 'create_reception', status: 'queued',
      idempotency_key: SecureRandom.uuid, company_cabinet_code: 'cabinet-1',
      execution_state: { 'request_snapshot' => { policy::BINDING_KEY => card.id, policy::SNAPSHOT_KEY => policy.current_snapshot(appointment) } }
    ).tap { |record| record.save!(validate: false) }
    { account: account, resource: resource, owner: owner, card: card, duplicate: duplicate, appointment: appointment, command: command }
  end

  # Mirrors Executor#with_patient_identity_write_fence: the command and its appointment are locked while the claim and the
  # write phase are published; other sessions see them only after this transaction commits.
  def hold_provider_write_fence(records, fence_locked, release_fence)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Integrations::Medelement::ProviderCommand.transaction do
          command = Integrations::Medelement::ProviderCommand.lock.find(records.fetch(:command).id)
          Scheduling::Appointment.lock.find(records.fetch(:appointment).id)
          command.update_columns(status: 'processing', execution_state: command.execution_state.merge('write_phase' => 'reception_create')) # rubocop:disable Rails/SkipsModelValidations
          fence_locked << true
          release_fence.pop
        end
      end
    end
  end

  def run_operator_merge(records, merge_backend, outcome)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        merge_backend << connection.select_value('SELECT pg_backend_pid()')
        ContactMergeAction.new(account: records.fetch(:account), base_contact: records.fetch(:duplicate),
                               mergee_contact: records.fetch(:card)).perform
        outcome << :merged
      end
    rescue StandardError => e
      outcome << e
    end
  end

  def wait_for_lock_wait(backend_pid)
    Timeout.timeout(10) do
      loop do
        waiting = ActiveRecord::Base.connection.select_value(
          "SELECT COUNT(*) FROM pg_locks WHERE pid = #{Integer(backend_pid)} AND NOT granted"
        ).to_i
        break if waiting.positive?

        sleep 0.02
      end
    end
  end

  def cleanup_race_records(records)
    account_id = records.fetch(:account).id
    Integrations::Medelement::ProviderCommand.where(account_id: account_id).delete_all
    Scheduling::Appointment.where(account_id: account_id).delete_all
    Contact.where(account_id: account_id).delete_all
    Scheduling::Resource.where(account_id: account_id).delete_all
    records.fetch(:account).reload.destroy!
  end
end
