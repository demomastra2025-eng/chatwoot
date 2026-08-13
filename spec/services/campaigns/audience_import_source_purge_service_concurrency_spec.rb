require 'rails_helper'
require 'timeout'

RSpec.describe Campaigns::AudienceImportSourcePurgeService do
  self.use_transactional_tests = false

  it 'fails a late attachment closed after serializing on the blob foreign key' do
    account = create(:account)
    channel = create(:channel_sms, account: account, phone_number: "+1555#{SecureRandom.random_number(10**10).to_s.rjust(10, '0')}")
    inbox = channel.inbox
    creator = create(:user, account: account, role: :administrator)
    first_import = create(:campaign_audience_import, account: account, inbox: inbox, created_by: creator)
    second_import = create(:campaign_audience_import, account: account, inbox: inbox, created_by: creator)
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("phone_number\n87051234567\n"),
      filename: 'recipients.csv',
      content_type: 'text/csv'
    )
    first_import.import_file.attach(blob)
    backend_pid = Queue.new
    delete_entered = Queue.new
    errors = Concurrent::Array.new
    original_delete = blob.service.method(:delete)
    allow(blob.service).to receive(:delete) do |key|
      delete_entered << true
      pid = Timeout.timeout(5) { backend_pid.pop }
      wait_for_backend_lock(pid)
      original_delete.call(key)
    end

    purge_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.new(audience_import: first_import).perform
      rescue StandardError => e
        errors << e
      end
    end
    Timeout.timeout(5) { delete_entered.pop }
    attach_thread = late_attachment_thread(
      audience_import: second_import,
      blob: blob,
      backend_pid: backend_pid,
      errors: errors
    )
    [purge_thread, attach_thread].each(&:join)

    expect(errors.one? { |error| error.cause.is_a?(PG::ForeignKeyViolation) }).to be(true)
    expect(ActiveStorage::Attachment.where(record: second_import, name: 'import_file')).not_to exist
    expect(ActiveStorage::Blob.where(id: blob.id)).not_to exist
    expect(ActiveStorage::Blob.service).not_to exist(blob.key)
  ensure
    cleanup_race_records(account, channel, creator, blob)
  end

  def wait_for_backend_lock(pid)
    deadline = 5.seconds.from_now
    loop do
      waiting = ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.select_value(<<~SQL.squish)
          SELECT wait_event_type = 'Lock'
          FROM pg_stat_activity
          WHERE pid = #{Integer(pid)}
        SQL
      end
      return if waiting
      raise 'attachment insert did not block on blob row lock' if Time.current >= deadline

      sleep 0.01
    end
  end

  def late_attachment_thread(audience_import:, blob:, backend_pid:, errors:)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        backend_pid << connection.select_value('SELECT pg_backend_pid()')
        connection.execute(<<~SQL.squish)
          INSERT INTO active_storage_attachments
            (name, record_type, record_id, blob_id, created_at)
          VALUES
            ('import_file', '#{CampaignAudienceImport.polymorphic_name}', #{audience_import.id}, #{blob.id}, #{connection.quote(Time.current)})
        SQL
      rescue StandardError => e
        errors << e
      end
    end
  end

  def cleanup_race_records(account, channel, creator, blob)
    cleanup_blob(blob) if blob
    cleanup_channel(channel) if channel
    cleanup_account(account) if account
    cleanup_creator(creator) if creator
  end

  def cleanup_blob(blob)
    ActiveStorage::Blob.service.delete(blob.key) if ActiveStorage::Blob.service.exist?(blob.key)
    ActiveStorage::Attachment.where(blob_id: blob.id).delete_all
    ActiveStorage::Blob.where(id: blob.id).delete_all
  end

  def cleanup_channel(channel)
    channel.inbox.destroy! if channel.inbox&.persisted?
    channel.destroy! if channel.persisted?
  end

  def cleanup_account(account)
    account.destroy! if account.persisted?
  end

  def cleanup_creator(creator)
    creator.destroy! if creator.persisted?
  end
end
