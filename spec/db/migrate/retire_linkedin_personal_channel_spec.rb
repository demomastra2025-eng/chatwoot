require 'spec_helper'
require 'active_record'

require_relative '../../../db/migrate/20260913090000_retire_linkedin_personal_channel'

RSpec.describe RetireLinkedinPersonalChannel do
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

  it 'installs write guards while preserving rollback configuration' do
    migration = described_class.new
    allow(migration).to receive(:assert_required_schema!)
    allow(migration).to receive(:count_rows).and_return(0)
    allow(migration).to receive(:count_where).and_return(0)
    allow(migration).to receive(:say)

    expect(migration.respond_to?(:remove_installation_configs, true)).to be(false)
    expect(migration).to receive(:install_write_guards)
    expect(migration).to receive(:say)
      .with('LinkedIn Personal schema cleanup is deferred until every process runs the compatibility release')

    migration.up
  end
end
