require 'rails_helper'
require 'timeout'

RSpec.describe Captain::Conversation::ActionFenceService do
  self.use_transactional_tests = false

  def create_records
    account = create(:account).tap { |record| record.enable_features!('scheduling') }
    contact = create(:contact, account: account)
    appointment = create(:scheduling_appointment, account: account, contact: contact,
                                                  custom_attributes: { 'medelement_provider_sync_status' => 'pending' })
    hook = create(:integrations_hook, :medelement, account: account)
    command = Integrations::Medelement::ProviderCommand.create!(
      account: account, appointment: appointment, contact: contact, hook: hook,
      operation: 'create_patient', status: 'v2_queued', idempotency_key: SecureRandom.uuid,
      execution_state: { 'captain_action_origin' => { 'source' => 'captain_actor' },
                         'request_snapshot' => { 'actor' => { 'type' => 'Captain::Assistant' } } }
    )
    appointment.update!(custom_attributes: appointment.custom_attributes.merge('medelement_provider_command_id' => command.id))
    { account: account, contact: contact, appointment: appointment, service: appointment.service,
      resource: appointment.resource, hook: hook, command: command }
  end

  def wait_for_block!(blocked_pid, blocker_pid)
    Timeout.timeout(15) do
      loop do
        blockers = ActiveRecord::Base.connection.select_value("SELECT pg_blocking_pids(#{blocked_pid})")
        break if blockers.include?(blocker_pid.to_s)

        sleep 0.01
      end
    end
  end

  # rubocop:disable RSpec/ExampleLength
  it 'takes the command row before appointment so outbound projection never deadlocks' do
    records = create_records
    command_id = records.fetch(:command).id
    appointment_id = records.fetch(:appointment).id
    held = Queue.new
    release = Queue.new
    started = Queue.new
    projector = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Integrations::Medelement::ProviderCommand.find(command_id).with_lock do
          held << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
          Timeout.timeout(20) { release.pop }
          service = Integrations::Medelement::OutboundChangeService.new(
            entity_type: 'appointment', entity_id: appointment_id, event_name: 'appointment_updated'
          )
          service.send(
            :project_appointment_provider_status!, Scheduling::Appointment.find(appointment_id),
            Integrations::Medelement::ProviderCommand.find(command_id)
          )
        end
      end
    rescue StandardError => e
      e
    end
    projector_pid = Timeout.timeout(20) { held.pop }
    canceller = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        started << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
        described_class.cancel_pending!(Integrations::Medelement::ProviderCommand.find(command_id))
      end
    rescue StandardError => e
      e
    end
    canceller_pid = Timeout.timeout(20) { started.pop }
    expect(canceller_pid).not_to eq(projector_pid)
    wait_for_block!(canceller_pid, projector_pid)

    # A cancelled receipt must not own the Appointment while it waits for the
    # ProviderCommand: the real projector needs Appointment after command.
    expect(Scheduling::Appointment.where(id: appointment_id).lock('FOR UPDATE NOWAIT').first).to be_present
    release << true
    result = Timeout.timeout(20) { projector.value }
    raise result if result.is_a?(StandardError)

    result = Timeout.timeout(20) { canceller.value }
    raise result if result.is_a?(StandardError)

    expect(Integrations::Medelement::ProviderCommand.find(command_id).status).to eq('cancelled')
    expect(Scheduling::Appointment.find(appointment_id).custom_attributes['medelement_provider_sync_status']).to eq('failed')
  ensure
    release&.push(true)
    [projector, canceller].compact.each do |worker|
      worker.join(5)
      worker.kill if worker.alive?
    end
    if defined?(records) && records
      %i[command appointment service resource hook contact account].each do |key|
        record = records.fetch(key)
        record.destroy! if record&.persisted?
      end
    end
  end
  # rubocop:enable RSpec/ExampleLength
end
