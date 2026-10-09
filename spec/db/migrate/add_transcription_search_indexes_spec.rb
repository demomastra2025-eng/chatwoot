require 'rails_helper'
require Rails.root.join('db/migrate/20261009170000_add_transcription_search_indexes')

# CREATE INDEX CONCURRENTLY runs outside the test transaction, just like the production migration.
RSpec.describe AddTranscriptionSearchIndexes do
  self.use_transactional_tests = false

  let(:db) { ActiveRecord::Base.connection }
  let(:names) { described_class::INDEXES.map { |index| index.fetch(:name) } }

  def migrate(direction = :up)
    ActiveRecord::Migration.suppress_messages { described_class.new.public_send(direction) }
  end

  def quoted_names
    names.map { |name| db.quote(name) }.join(', ')
  end

  def index_validity
    db.select_rows(<<~SQL.squish).to_h
      SELECT pg_class.relname, pg_index.indisvalid FROM pg_index
      JOIN pg_class ON pg_class.oid = pg_index.indexrelid
      WHERE pg_class.relname IN (#{quoted_names})
    SQL
  end

  def index_definitions
    db.select_rows(<<~SQL.squish).to_h
      SELECT indexname, indexdef FROM pg_indexes
      WHERE schemaname = current_schema() AND indexname IN (#{quoted_names})
    SQL
  end

  before { names.each { |name| db.execute("DROP INDEX IF EXISTS #{db.quote_table_name(name)}") } }

  after(:all) { described_class.new.tap { |migration| ActiveRecord::Migration.suppress_messages { migration.up } } }

  it 'builds valid trigram indexes for the exact runtime candidate expressions' do
    migrate

    definitions = index_definitions
    message_definition = definitions.fetch('index_messages_on_transcription_search_text')
    attachment_definition = definitions.fetch('index_attachments_on_transcribed_text')

    aggregate_failures do
      expect(index_validity).to eq(names.index_with { true })
      expect(message_definition).to include('USING gin', 'gin_trgm_ops', 'processed_message_content', 'text_content', 'transcribed_text', 'subject')
      expect(attachment_definition).to include('USING gin', "meta ->> 'transcribed_text'", 'gin_trgm_ops')
      expect(Search::ConversationLookup::TRANSCRIPTION_SEARCH_TEXT_SQL.gsub('messages.', '')).to eq(described_class::MESSAGE_SEARCH_TEXT)
    end
  end

  it 'repairs an invalid interrupted concurrent index and can run repeatedly' do
    migrate
    db.execute("UPDATE pg_index SET indisvalid = FALSE WHERE indexrelid = 'index_attachments_on_transcribed_text'::regclass")

    migrate

    expect(index_validity).to eq(names.index_with { true })
    definitions = index_definitions
    migrate
    expect(index_definitions).to eq(definitions)
  end

  it 'analyzes both tables on a successful rerun when the valid indexes already exist' do
    migrate
    analyzed_tables = []
    subscriber = lambda do |_name, _start, _finish, _id, payload|
      sql = payload[:sql]
      analyzed_tables << sql[/\AANALYZE\s+"?(\w+)"?/i, 1] if sql
    end

    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') { migrate }
    table_stats = db.select_rows(<<~SQL.squish).to_h
      SELECT relname, last_analyze FROM pg_stat_all_tables
      WHERE schemaname = current_schema() AND relname IN ('messages', 'attachments')
    SQL

    aggregate_failures do
      expect(analyzed_tables).to contain_exactly('messages', 'attachments')
      expect(table_stats.keys).to contain_exactly('messages', 'attachments')
      expect(table_stats.values).to all(be_present)
    end
  end

  it 'drops the search indexes on rollback' do
    migrate
    migrate(:down)

    expect(index_validity).to be_empty
  end
end
