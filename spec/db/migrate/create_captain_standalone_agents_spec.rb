require 'rails_helper'
require Rails.root.join('db/migrate/20261011080000_create_captain_standalone_agents')

RSpec.describe CreateCaptainStandaloneAgents do
  let(:account) { create(:account) }
  let(:parent) { create(:captain_assistant, account: account, description: 'Parent main instruction') }
  let!(:scenario) { create(:captain_scenario, assistant: parent, account: account, instruction: 'Scenario own instruction') }
  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }

  it 'can be rerun without duplicating or replacing the mapped agents' do
    migration = described_class.new
    ActiveRecord::Migration.suppress_messages { migration.up }
    agent = Captain::Assistant.find_by!(legacy_scenario_id: scenario.id)
    agent.update!(description: 'Independent edited instruction')
    agent.outgoing_agent_handoffs.delete_all

    expect do
      ActiveRecord::Migration.suppress_messages { migration.up }
    end.not_to change(Captain::Assistant, :count)

    expect(agent.reload.description).to eq('Independent edited instruction')
    expect(agent.handoff_agent_ids).to be_empty
    expect(Captain::Scenario.find(scenario.id).instruction).to eq('Scenario own instruction')
  end

  it 'keeps unique stable legacy mappings at the database boundary' do
    ActiveRecord::Migration.suppress_messages { described_class.new.up }
    duplicate = build(:captain_assistant, account: account, legacy_scenario_id: scenario.id)

    expect do
      Captain::Assistant.transaction(requires_new: true) { duplicate.save!(validate: false) }
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it 'refuses a destructive rollback of converted history' do
    expect { described_class.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
  end

  it 'retains the scenario and stable converted mapping when the former parent is deleted' do
    ActiveRecord::Migration.suppress_messages { migration.up }
    converted = Captain::Assistant.find_by!(legacy_scenario_id: scenario.id)

    parent.destroy!

    expect(scenario.reload).to have_attributes(assistant_id: nil, instruction: 'Scenario own instruction')
    expect(converted.reload.legacy_scenario_id).to eq(scenario.id)
  end

  it 'adds NOT VALID constraints that already reject new cross-account handoffs, then validates existing rows' do
    name = 'captain_agent_handoffs_target_assistant_id_account_fk'
    connection.remove_foreign_key :captain_agent_handoffs, name: name
    connection.remove_check_constraint :captain_agent_handoffs, name: 'captain_agent_handoffs_no_self'

    ActiveRecord::Migration.suppress_messages { migration.send(:add_constraints) }

    expect(connection.foreign_keys(:captain_agent_handoffs).find { |key| key.name == name }).not_to be_validated
    expect(connection.check_constraints(:captain_agent_handoffs).find { |check| check.name == 'captain_agent_handoffs_no_self' }.validate?).to be false
    foreign_target = create(:captain_assistant)
    expect do
      Captain::AgentHandoff.transaction(requires_new: true) do
        Captain::AgentHandoff.new(account: account, source_assistant: parent, target_assistant: foreign_target).save!(validate: false)
      end
    end.to raise_error(ActiveRecord::InvalidForeignKey)

    ActiveRecord::Migration.suppress_messages { migration.send(:validate_constraints) }
    expect(connection.foreign_keys(:captain_agent_handoffs)).to all(be_validated)
    expect(connection.check_constraints(:captain_agent_handoffs).find { |check| check.name == 'captain_agent_handoffs_no_self' }.validate?).to be true
  end

  it 'requests a concurrent build when an existing-table mapping index is absent' do
    connection.remove_index :captain_assistants, name: 'index_captain_assistants_on_legacy_scenario_id'
    algorithms = []
    allow(connection).to receive(:add_index).and_wrap_original do |original, *args, **options|
      algorithms << options[:algorithm]
      original.call(*args, **options.except(:algorithm))
    end

    ActiveRecord::Migration.suppress_messages { migration.up }

    expect(algorithms).to eq([:concurrently])
    expect(Captain::Assistant.find_by!(legacy_scenario_id: scenario.id).description).to include('Scenario own instruction')
  end

  it 'bounds every lock attempt and stops after the configured retry limit' do
    attempts = []
    allow(migration).to receive(:sleep)

    expect do
      ActiveRecord::Migration.suppress_messages do
        migration.send(:with_short_lock_timeout) do
          attempts << connection.select_value('SHOW lock_timeout')
          raise ActiveRecord::LockWaitTimeout, 'Synthetic lock contention'
        end
      end
    end.to raise_error(ActiveRecord::LockWaitTimeout)

    expect(attempts).to eq(['5s'] * described_class::LOCK_ATTEMPTS)
    expect(migration).to have_received(:sleep).exactly(described_class::LOCK_ATTEMPTS - 1).times
  end
end
