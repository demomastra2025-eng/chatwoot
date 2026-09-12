require 'rails_helper'
require Rails.root.join('db/migrate/20260912180000_add_english_search_vector_index_to_messages')

RSpec.describe AddEnglishSearchVectorIndexToMessages do
  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }

  before do
    allow(migration).to receive(:connection).and_return(connection)
    allow(connection).to receive(:select_value).and_return(true)
  end

  it 'recreates an invalid interrupted concurrent index' do
    allow(connection).to receive(:select_one).and_return(
      'valid' => false,
      'definition' => "CREATE INDEX #{described_class::INDEX_NAME} ON messages USING gin (content)"
    )

    expect(connection).to receive(:execute)
      .with("DROP INDEX CONCURRENTLY IF EXISTS #{described_class::INDEX_NAME}").ordered
    expect(connection).to receive(:execute).with(a_string_including('CREATE INDEX CONCURRENTLY')).ordered

    migration.up
  end

  it 'keeps a valid index with the expected expression' do
    allow(connection).to receive(:select_one).and_return(
      'valid' => true,
      'definition' => "CREATE INDEX #{described_class::INDEX_NAME} ON messages USING gin (#{described_class::EXPECTED_EXPRESSION})"
    )

    expect(connection).not_to receive(:execute)

    migration.up
  end

  it 'fails before changing search semantics when the database default is not English' do
    allow(connection).to receive(:select_value).and_return(false)
    expect(connection).not_to receive(:execute)

    expect { migration.up }.to raise_error(
      ActiveRecord::MigrationError,
      /default_text_search_config must be English before installing the message search index/
    )
  end
end
