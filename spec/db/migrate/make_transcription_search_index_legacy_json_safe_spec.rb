require 'rails_helper'
require Rails.root.join('db/migrate/20261009180000_make_transcription_search_index_legacy_json_safe')

# The forward repair must replace the already-published unsafe message expression without disturbing attachments.
RSpec.describe MakeTranscriptionSearchIndexLegacyJsonSafe do
  self.use_transactional_tests = false

  let(:db) { ActiveRecord::Base.connection }
  let(:message_index) { described_class::MESSAGE_INDEX_NAME }
  let(:attachment_index) { 'index_attachments_on_transcribed_text' }

  def migrate
    ActiveRecord::Migration.suppress_messages { described_class.new.up }
  end

  def rollback
    ActiveRecord::Migration.suppress_messages { described_class.new.down }
  end

  def index_definition(name)
    db.select_value(<<~SQL.squish)
      SELECT pg_get_indexdef(pg_class.oid)
      FROM pg_class
      JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
      WHERE pg_class.relname = #{db.quote(name)}
        AND pg_namespace.nspname = ANY (current_schemas(false))
    SQL
  end

  def index_oid(name)
    db.select_value(<<~SQL.squish)
      SELECT pg_class.oid::text
      FROM pg_class
      JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
      WHERE pg_class.relname = #{db.quote(name)}
        AND pg_namespace.nspname = ANY (current_schemas(false))
    SQL
  end

  def valid_index?(name)
    db.select_value(<<~SQL.squish)
      SELECT pg_index.indisvalid
      FROM pg_index
      JOIN pg_class ON pg_class.oid = pg_index.indexrelid
      JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
      WHERE pg_class.relname = #{db.quote(name)}
        AND pg_namespace.nspname = ANY (current_schemas(false))
    SQL
  end

  def create_old_style_message_index
    db.execute(<<~SQL.squish)
      CREATE INDEX CONCURRENTLY #{db.quote_table_name(message_index)}
      ON messages USING gin ((COALESCE(processed_message_content, ''::text)) gin_trgm_ops)
    SQL
  end

  before do
    db.execute("DROP INDEX IF EXISTS #{db.quote_table_name(message_index)}")
  end

  after(:all) do
    ActiveRecord::Migration.suppress_messages { described_class.new.up }
  end

  it 'replaces a valid old-style message index and leaves the attachment index unchanged' do
    attachment_definition_before = index_definition(attachment_index)
    create_old_style_message_index

    migrate

    message_definition = index_definition(message_index)
    aggregate_failures do
      expect(valid_index?(message_index)).to be(true)
      expect(message_definition).to include('USING gin', 'gin_trgm_ops', 'IS JSON OBJECT', 'processed_message_content',
                                            'text_content', 'transcribed_text', 'subject')
      expect(index_definition(attachment_index)).to eq(attachment_definition_before)
      runtime_expression = Search::ConversationLookup::TRANSCRIPTION_SEARCH_TEXT_SQL.gsub('messages.', '')
      expect(runtime_expression).to eq(described_class::MESSAGE_SEARCH_TEXT)
    end
  end

  it 'keeps the valid safe index on retries and analyzes the messages table' do
    migrate
    original_oid = index_oid(message_index)
    analyzed_messages = false
    subscriber = lambda do |_name, _start, _finish, _id, payload|
      analyzed_messages ||= payload[:sql]&.match?(/\AANALYZE\s+"?messages"?/i)
    end

    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') { migrate }

    aggregate_failures do
      expect(index_oid(message_index)).to eq(original_oid)
      expect(valid_index?(message_index)).to be(true)
      expect(analyzed_messages).to be(true)
    end
  end

  it 'repairs an interrupted concurrent build and rollback drops only the message index' do
    migrate
    db.execute("UPDATE pg_index SET indisvalid = FALSE WHERE indexrelid = #{db.quote(message_index)}::regclass")

    migrate
    attachment_definition_before = index_definition(attachment_index)

    rollback

    aggregate_failures do
      expect(valid_index?(message_index)).to be_nil
      expect(index_definition(attachment_index)).to eq(attachment_definition_before)
    end
  end
end
