require 'spec_helper'
require 'active_record'

require_relative '../../../db/migrate/20260831233823_remove_linkedin_personal_channel'

RSpec.describe RemoveLinkedinPersonalChannel do
  it 'fails closed when the expected compatibility schema is missing' do
    migration = described_class.new
    connection = instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter, table_exists?: false)
    allow(migration).to receive(:connection).and_return(connection)

    expect { migration.up }
      .to raise_error(ActiveRecord::IrreversibleMigration, /preflight schema missing/)
  end

  it 'blocks the compatibility rollout while LinkedIn Personal inboxes exist' do
    migration = described_class.new
    allow(migration).to receive(:assert_required_schema!)
    allow(migration).to receive(:count_rows).and_return(0)
    allow(migration).to receive(:count_where).and_return(1)

    expect { migration.up }
      .to raise_error(ActiveRecord::IrreversibleMigration, /inboxes=1/)
  end

  it 'defers destructive cleanup to the contract release' do
    migration = described_class.new
    allow(migration).to receive(:assert_required_schema!)
    allow(migration).to receive(:count_rows).and_return(0)
    allow(migration).to receive(:count_where).and_return(0)

    expect(migration).to receive(:say)
      .with('LinkedIn Personal schema removal is deferred to a contract release after the compatibility rollout')
    expect(migration).to receive(:install_write_guards)

    migration.up
  end
end
