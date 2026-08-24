require 'rails_helper'

RSpec.describe Integrations::Medelement::ProviderCommandJob do
  let(:first_appointment) { instance_double(Scheduling::Appointment, resource_id: 101) }
  let(:second_appointment) { instance_double(Scheduling::Appointment, resource_id: 202) }
  let(:first_command) do
    instance_double(
      Integrations::Medelement::ProviderCommand,
      hook_id: 7,
      contact_id: 55,
      request_snapshot: { 'reception' => { 'resource_id' => 101 } },
      appointment: first_appointment
    )
  end
  let(:second_command) do
    instance_double(
      Integrations::Medelement::ProviderCommand,
      hook_id: 7,
      contact_id: 55,
      request_snapshot: { 'reception' => { 'resource_id' => 202 } },
      appointment: second_appointment
    )
  end

  it 'uses a queue that legacy worker images do not poll' do
    expect(described_class.queue_name).to eq('medelement_provider_commands')
    expect(Integrations::Medelement::ProviderCommandConfirmationJob.queue_name).to eq('medelement_provider_commands')
    expect(Integrations::Medelement::ProviderCommandReconciliationJob.queue_name).to eq('medelement_provider_commands')
  end

  it 'serializes patient identity across different appointment resources' do
    first_keys = described_class.new.lock_keys(first_command)
    second_keys = described_class.new.lock_keys(second_command)

    expect(first_keys.length).to eq(2)
    expect(second_keys.length).to eq(2)
    expect(first_keys & second_keys).to contain_exactly(a_string_including('contact-55'))
  end

  it 'uses the same deterministic lock order during reconciliation' do
    execution_keys = described_class.new.lock_keys(first_command)
    reconciliation_keys = Integrations::Medelement::ProviderCommandReconciliationJob.new.send(:lock_keys, first_command)

    expect(reconciliation_keys).to eq(execution_keys)
    expect(execution_keys).to eq(execution_keys.sort)
  end

  it 'keeps using the immutable resource after the appointment moves' do
    command = instance_double(
      Integrations::Medelement::ProviderCommand,
      hook_id: 7,
      contact_id: nil,
      request_snapshot: { 'reception' => { 'resource_id' => 101 } },
      appointment: instance_double(Scheduling::Appointment, resource_id: 999)
    )
    expected_key = format(Redis::RedisKeys::MEDELEMENT_PROVIDER_COMMAND_MUTEX, hook_id: 7, target_id: 101)

    expect(described_class.new.lock_keys(command)).to contain_exactly(expected_key)
    expect(Integrations::Medelement::ProviderCommandReconciliationJob.new.send(:lock_keys, command)).to contain_exactly(expected_key)
  end

  it 'falls back to the current resource for legacy snapshots' do
    command = instance_double(
      Integrations::Medelement::ProviderCommand,
      hook_id: 7,
      contact_id: nil,
      request_snapshot: {},
      appointment: first_appointment
    )
    expected_key = format(Redis::RedisKeys::MEDELEMENT_PROVIDER_COMMAND_MUTEX, hook_id: 7, target_id: 101)

    expect(described_class.new.lock_keys(command)).to contain_exactly(expected_key)
  end
end
