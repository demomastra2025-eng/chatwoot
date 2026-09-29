require 'rails_helper'

RSpec.describe CommittedRowsCleanup do
  let(:connection) do
    instance_double(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter, tables: %w[accounts inboxes schema_migrations ar_internal_metadata])
  end

  before do
    allow(connection).to receive(:transaction).and_yield
    allow(connection).to receive(:execute)
    allow(connection).to receive(:quote_table_name) { |name| %("#{name}") }
  end

  it 'truncates every table except the schema metadata in one statement on the test database' do
    allow(connection).to receive(:current_database).and_return('chatwoot_test')

    described_class.truncate!(connection)

    expect(connection).to have_received(:execute).with("SET LOCAL statement_timeout = '120s'").ordered
    expect(connection).to have_received(:execute).with('TRUNCATE TABLE "accounts", "inboxes"').ordered
  end

  it 'accepts a numbered test database' do
    allow(connection).to receive(:current_database).and_return('chatwoot_test5')

    described_class.truncate!(connection)

    expect(connection).to have_received(:execute).with('TRUNCATE TABLE "accounts", "inboxes"')
  end

  %w[chatwoot_production chatwoot_dev chatwoot onelink_test_backup].each do |database|
    it "refuses to truncate #{database}" do
      allow(connection).to receive(:current_database).and_return(database)

      expect { described_class.truncate!(connection) }.to raise_error(RuntimeError, /Refusing to truncate #{database}/)
      expect(connection).not_to have_received(:execute)
    end
  end

  it 'refuses to truncate outside the test environment' do
    allow(connection).to receive(:current_database).and_return('chatwoot_test')
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new('development'))

    expect { described_class.truncate!(connection) }.to raise_error(RuntimeError, /Refusing to truncate chatwoot_test/)
    expect(connection).not_to have_received(:execute)
  end
end
