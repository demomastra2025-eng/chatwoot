# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20261004193000_create_captain_follow_up_attempts')
require Rails.root.join('db/migrate/20261004193100_add_idempotency_key_to_reminders')

RSpec.describe CreateCaptainFollowUpAttempts do
  before(:example, :captain_migration_schema_ddl) do
    @captain_migration_ddl_connection = ActiveRecord::Base.connection
  end

  def after_teardown
    captain_migration_ddl_connection = @captain_migration_ddl_connection
    super
  ensure
    if captain_migration_ddl_connection
      captain_migration_ddl_connection.clear_cache!
      %w[captain_follow_up_attempts reminders].each do |table_name|
        captain_migration_ddl_connection.schema_cache.clear_data_source_cache!(table_name)
      end
      Captain::FollowUpAttempt.reset_column_information
      Reminder.reset_column_information
      @captain_migration_ddl_connection = nil
    end
  end

  it 'preserves completed attempts and reminder receipts when existing migrations are reapplied' do
    account = create(:account)
    inbox = create(:inbox, account: account)
    conversation = create(:conversation, account: account, inbox: inbox)
    assistant = create(:captain_assistant, account: account)
    anchor_message = create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      message_type: :outgoing,
      content: 'Original follow-up anchor'
    )
    processing_started_at = Time.utc(2026, 9, 1, 10, 0, 0, 125_000)
    generated_at = processing_started_at + 5.seconds
    completed_at = generated_at + 2.seconds
    expires_at = completed_at + 30.days
    attempt = Captain::FollowUpAttempt.create!(
      account: account,
      assistant: assistant,
      conversation: conversation,
      anchor_message: anchor_message,
      step_index: 2,
      attempt_key: "captain-follow-up-migration-#{SecureRandom.hex(8)}",
      generated_content: 'Generated follow-up content retained as execution history',
      status: 'completed',
      processing_started_at: processing_started_at,
      generated_at: generated_at,
      completed_at: completed_at,
      expires_at: expires_at
    )
    reminder = create(
      :reminder,
      account: account,
      conversation: conversation,
      action_type: :send_message,
      status: :completed,
      idempotency_key: "migration-preserved-key-#{SecureRandom.hex(8)}",
      scheduled_at: processing_started_at + 1.hour,
      completed_at: completed_at,
      body: 'Previously delivered reminder content'
    )
    attempt_attributes = attempt.reload.attributes
    reminder_attributes = reminder.reload.attributes

    2.times do
      described_class.new.up
      AddIdempotencyKeyToReminders.new.up
    end

    expect(attempt.reload.attributes).to eq(attempt_attributes)
    expect(reminder.reload.attributes).to eq(reminder_attributes)
    idempotency_index = ActiveRecord::Base.connection.indexes(:reminders).find do |index|
      index.name == 'idx_reminders_on_account_idempotency_key'
    end
    expect(idempotency_index).to have_attributes(
      columns: %w[account_id idempotency_key],
      unique: true
    )
    expect(idempotency_index.where).to match(/idempotency_key\s+IS\s+NOT\s+NULL/i)
  end

  it 'rejects an existing attempt key index that is not unique', :captain_migration_schema_ddl do
    connection = ActiveRecord::Base.connection
    index_name = 'index_captain_follow_up_attempts_on_attempt_key'
    connection.remove_index(:captain_follow_up_attempts, name: index_name)
    connection.add_index(:captain_follow_up_attempts, :attempt_key, name: index_name)

    expect { described_class.new.up }.to raise_error(
      ActiveRecord::MigrationError, /does not match the Captain attempt contract/
    )
  end

  it 'rejects an existing attempt foreign key that is not validated', :captain_migration_schema_ddl do
    connection = ActiveRecord::Base.connection
    foreign_key = connection.foreign_keys(:captain_follow_up_attempts).find do |candidate|
      candidate.column == 'account_id'
    end
    connection.remove_foreign_key(:captain_follow_up_attempts, name: foreign_key.name)
    connection.add_foreign_key(
      :captain_follow_up_attempts,
      :accounts,
      column: :account_id,
      on_delete: :cascade,
      validate: false,
      name: foreign_key.name
    )

    expect { described_class.new.up }.to raise_error(
      ActiveRecord::MigrationError, /foreign key does not match the Captain attempt contract/
    )
  end

  it 'rejects a timestamp column with reduced precision', :captain_migration_schema_ddl do
    ActiveRecord::Base.connection.change_column(
      :captain_follow_up_attempts, :processing_started_at, :datetime, precision: 3
    )

    expect { described_class.new.up }.to raise_error(
      ActiveRecord::MigrationError, /processing_started_at precision does not match the Captain attempt contract/
    )
  end

  it 'rejects an attempt status default that includes SQL quotes in its value', :captain_migration_schema_ddl do
    ActiveRecord::Base.connection.change_column_default(:captain_follow_up_attempts, :status, "'processing'")

    expect { described_class.new.up }.to raise_error(
      ActiveRecord::MigrationError, /status default does not match the Captain attempt contract/
    )
  end

  it 'rejects an attempt primary key without its ID sequence', :captain_migration_schema_ddl do
    ActiveRecord::Base.connection.change_column_default(:captain_follow_up_attempts, :id, nil)

    expect { described_class.new.up }.to raise_error(
      ActiveRecord::MigrationError, /id default does not match the Captain attempt contract/
    )
  end

  it 'rejects a reminder index whose quoted predicate targets a different column', :captain_migration_schema_ddl do
    connection = ActiveRecord::Base.connection
    index_name = 'idx_reminders_on_account_idempotency_key'
    connection.add_column(:reminders, :IDEMPOTENCY_KEY, :string)
    connection.remove_index(:reminders, name: index_name)
    connection.add_index(
      :reminders,
      %i[account_id idempotency_key],
      unique: true,
      where: '"IDEMPOTENCY_KEY" IS NOT NULL',
      name: index_name
    )

    expect { AddIdempotencyKeyToReminders.new.up }.to raise_error(
      ActiveRecord::MigrationError, /does not match the reminder idempotency contract/
    )
  end

  it 'rejects a reminder idempotency index without the required partial predicate', :captain_migration_schema_ddl do
    connection = ActiveRecord::Base.connection
    index_name = 'idx_reminders_on_account_idempotency_key'
    connection.remove_index(:reminders, name: index_name)
    connection.add_index(:reminders, %i[account_id idempotency_key], unique: true, name: index_name)

    expect { AddIdempotencyKeyToReminders.new.up }.to raise_error(
      ActiveRecord::MigrationError, /does not match the reminder idempotency contract/
    )
  end
end
