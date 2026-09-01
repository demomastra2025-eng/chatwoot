require 'spec_helper'
require 'active_record'

require_relative '../../../db/migrate/20260901011206_remove_agent_bots'

RSpec.describe RemoveAgentBots do
  it 'fails closed when the expected compatibility schema is missing' do
    migration = described_class.new
    connection = instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter, table_exists?: false)
    allow(migration).to receive(:connection).and_return(connection)

    expect { migration.up }
      .to raise_error(ActiveRecord::IrreversibleMigration, /preflight schema missing/)
  end

  it 'blocks the compatibility rollout while any AgentBot references exist' do
    migration = described_class.new
    allow(migration).to receive(:assert_required_schema!)
    allow(migration).to receive(:count_rows).and_return(0)
    allow(migration).to receive(:count_where).and_return(0, 1, 0, 0, 0)

    expect { migration.up }
      .to raise_error(ActiveRecord::IrreversibleMigration, /messages=1/)
  end

  it 'defers destructive cleanup to the contract release' do
    migration = described_class.new
    allow(migration).to receive(:assert_required_schema!)
    allow(migration).to receive(:count_rows).and_return(0)
    allow(migration).to receive(:count_where).and_return(0)

    expect(migration).to receive(:say)
      .with('AgentBot schema removal is deferred to a contract release after the compatibility rollout')
    expect(migration).to receive(:install_write_guards)

    migration.up
  end
end
