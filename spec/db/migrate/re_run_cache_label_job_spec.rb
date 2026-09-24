require 'rails_helper'
require Rails.root.join('db/migrate/20231219000743_re_run_cache_label_job')

RSpec.describe ReRunCacheLabelJob do
  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }

  before { clear_enqueued_jobs }

  after do
    connection.execute('DROP TABLE IF EXISTS pg_temp.accounts')
    connection.execute('DROP TABLE IF EXISTS pg_temp.conversations')
    connection.execute('DROP TABLE IF EXISTS pg_temp.tags')
    connection.execute('DROP TABLE IF EXISTS pg_temp.taggings')
    described_class::MigrationConversation.reset_column_information
    connection.schema_cache.clear!
    clear_enqueued_jobs
  end

  def use_historical_accounts_table
    connection.execute('CREATE TEMP TABLE accounts (id bigserial PRIMARY KEY, status integer DEFAULT 0) ON COMMIT DROP')
  end

  def use_historical_label_tables(text_cache: false)
    cache_type = text_cache ? 'text' : 'varchar(255)'
    connection.execute(<<~SQL.squish)
      CREATE TEMP TABLE conversations (
        id bigserial PRIMARY KEY, account_id bigint, cached_label_list #{cache_type}
      ) ON COMMIT DROP
    SQL
    connection.execute('CREATE TEMP TABLE tags (id bigserial PRIMARY KEY, name varchar(255)) ON COMMIT DROP')
    connection.execute(<<~SQL.squish)
      CREATE TEMP TABLE taggings (
        id bigserial PRIMARY KEY, tag_id bigint, taggable_id bigint,
        taggable_type varchar(255), context varchar(255), tagger_id bigint
      ) ON COMMIT DROP
    SQL
  end

  it 'rebuilds active historical labels without starting a worker on the old schema' do
    use_historical_accounts_table
    use_historical_label_tables
    active_id = connection.select_value('INSERT INTO accounts (status) VALUES (0) RETURNING id').to_i
    suspended_id = connection.select_value('INSERT INTO accounts (status) VALUES (1) RETURNING id').to_i
    labelled_id = connection.select_value("INSERT INTO conversations (account_id) VALUES (#{active_id}) RETURNING id").to_i
    empty_id = connection.select_value("INSERT INTO conversations (account_id) VALUES (#{active_id}) RETURNING id").to_i
    cached_id = connection.select_value(
      "INSERT INTO conversations (account_id, cached_label_list) VALUES (#{active_id}, 'Existing') RETURNING id"
    ).to_i
    suspended_conversation_id = connection.select_value("INSERT INTO conversations (account_id) VALUES (#{suspended_id}) RETURNING id").to_i
    connection.execute("INSERT INTO tags (id, name) VALUES (1, 'VIP'), (2, 'hot'), (3, 'Ignored')")
    connection.execute(<<~SQL.squish)
      INSERT INTO taggings (tag_id, taggable_id, taggable_type, context, tagger_id) VALUES
        (1, #{labelled_id}, 'Conversation', 'labels', NULL),
        (2, #{labelled_id}, 'Conversation', 'labels', NULL),
        (3, #{labelled_id}, 'Conversation', 'labels', 42),
        (3, #{labelled_id}, 'Conversation', 'other', NULL),
        (3, #{labelled_id}, 'Contact', 'labels', NULL),
        (3, #{cached_id}, 'Conversation', 'labels', NULL),
        (3, #{suspended_conversation_id}, 'Conversation', 'labels', NULL)
    SQL

    migration.migrate(:up)

    expect(connection.select_value("SELECT cached_label_list FROM conversations WHERE id = #{labelled_id}")).to eq('VIP, hot')
    expect(connection.select_value("SELECT cached_label_list FROM conversations WHERE id = #{empty_id}")).to eq('')
    expect(connection.select_value("SELECT cached_label_list FROM conversations WHERE id = #{cached_id}")).to eq('Existing')
    expect(connection.select_value("SELECT cached_label_list FROM conversations WHERE id = #{suspended_conversation_id}")).to be_nil
    expect(enqueued_jobs).to be_empty

    connection.execute("UPDATE conversations SET cached_label_list = 'Edited' WHERE id = #{labelled_id}")
    migration.migrate(:down)
    migration.migrate(:up)

    expect(connection.select_value("SELECT cached_label_list FROM conversations WHERE id = #{labelled_id}")).to eq('Edited')
    expect(enqueued_jobs).to be_empty
  end

  it 'does not enqueue jobs or fail on an empty historical accounts table' do
    use_historical_accounts_table
    use_historical_label_tables

    migration.migrate(:up)
    migration.migrate(:down)
    migration.migrate(:up)

    expect(enqueued_jobs).to be_empty
  end

  it 'processes more than one batch and leaves already-cached conversations untouched on retry' do
    use_historical_accounts_table
    use_historical_label_tables
    active_id = connection.select_value('INSERT INTO accounts (status) VALUES (0) RETURNING id').to_i
    connection.execute("INSERT INTO conversations (account_id) SELECT #{active_id} FROM generate_series(1, 1001)")

    migration.migrate(:up)
    migration.migrate(:down)
    migration.migrate(:up)

    expect(connection.select_value("SELECT COUNT(*) FROM conversations WHERE cached_label_list = ''").to_i).to eq(1001)
    expect(enqueued_jobs).to be_empty
  end

  it 'preserves labels longer than the historical cache column before the later text migration' do
    use_historical_accounts_table
    use_historical_label_tables
    account_id = connection.select_value('INSERT INTO accounts (status) VALUES (0) RETURNING id').to_i
    conversation_id = connection.select_value("INSERT INTO conversations (account_id) VALUES (#{account_id}) RETURNING id").to_i
    first_label = 'A' * 130
    second_label = 'B' * 130
    expected_cache = "#{first_label}, #{second_label}"
    connection.execute("INSERT INTO tags (id, name) VALUES (1, '#{first_label}'), (2, '#{second_label}')")
    connection.execute(<<~SQL.squish)
      INSERT INTO taggings (tag_id, taggable_id, taggable_type, context) VALUES
        (1, #{conversation_id}, 'Conversation', 'labels'),
        (2, #{conversation_id}, 'Conversation', 'labels')
    SQL

    expect(connection.columns(:conversations).find { |column| column.name == 'cached_label_list' }.type).to eq(:string)
    migration.migrate(:up)

    expect(connection.columns(:conversations).find { |column| column.name == 'cached_label_list' }.type).to eq(:text)
    expect(connection.select_value("SELECT cached_label_list FROM conversations WHERE id = #{conversation_id}")).to eq(expected_cache)
    expect(enqueued_jobs).to be_empty

    migration.migrate(:down)
    migration.migrate(:up)
    expect(connection.select_value("SELECT cached_label_list FROM conversations WHERE id = #{conversation_id}")).to eq(expected_cache)
  end

  it 'keeps the first tag spelling and order but deduplicates case variants and blank names' do
    use_historical_accounts_table
    use_historical_label_tables
    account_id = connection.select_value('INSERT INTO accounts (status) VALUES (0) RETURNING id').to_i
    conversation_id = connection.select_value("INSERT INTO conversations (account_id) VALUES (#{account_id}) RETURNING id").to_i
    connection.execute("INSERT INTO tags (id, name) VALUES (1, 'VIP'), (2, 'vip'), (3, 'Hot'), (4, ' HOT '), (5, '   ')")
    connection.execute(<<~SQL.squish)
      INSERT INTO taggings (tag_id, taggable_id, taggable_type, context) VALUES
        (1, #{conversation_id}, 'Conversation', 'labels'),
        (2, #{conversation_id}, 'Conversation', 'labels'),
        (3, #{conversation_id}, 'Conversation', 'labels'),
        (1, #{conversation_id}, 'Conversation', 'labels'),
        (4, #{conversation_id}, 'Conversation', 'labels'),
        (5, #{conversation_id}, 'Conversation', 'labels')
    SQL

    migration.migrate(:up)

    expect(connection.select_value("SELECT cached_label_list FROM conversations WHERE id = #{conversation_id}")).to eq('VIP, Hot')
    expect(enqueued_jobs).to be_empty
  end

  it 'rebuilds on the current Account schema without dispatching work to Sidekiq' do
    use_historical_label_tables(text_cache: true)
    active_id = connection.select_value(
      'INSERT INTO accounts (name, status, created_at, updated_at) ' \
      "VALUES ('Stage G active', 0, NOW(), NOW()) RETURNING id"
    ).to_i
    connection.execute("INSERT INTO accounts (name, status, created_at, updated_at) VALUES ('Stage G suspended', 1, NOW(), NOW())")
    conversation_id = connection.select_value("INSERT INTO conversations (account_id) VALUES (#{active_id}) RETURNING id").to_i
    connection.execute("INSERT INTO tags (id, name) VALUES (1, 'VIP')")
    connection.execute("INSERT INTO taggings (tag_id, taggable_id, taggable_type, context) VALUES (1, #{conversation_id}, 'Conversation', 'labels')")

    migration.migrate(:up)

    expect(connection.columns(:conversations).find { |column| column.name == 'cached_label_list' }.type).to eq(:text)
    expect(connection.select_value("SELECT cached_label_list FROM conversations WHERE id = #{conversation_id}")).to eq('VIP')
    expect(enqueued_jobs).to be_empty
  end
end
