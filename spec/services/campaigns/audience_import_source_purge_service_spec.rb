require 'rails_helper'

RSpec.describe Campaigns::AudienceImportSourcePurgeService do
  def attach_source(audience_import, blob = nil)
    source = blob || {
      io: StringIO.new("phone_number\n87051234567\n"),
      filename: 'recipients.csv',
      content_type: 'text/csv'
    }
    audience_import.import_file.attach(source)
  end

  it 'retains the attachment marker after a storage error and succeeds on retry for a claimed import' do
    audience_import = create(:campaign_audience_import, status: :completed, claimed_at: Time.current)
    attach_source(audience_import)
    blob = audience_import.import_file.blob
    delete_attempts = 0
    allow(blob.service).to receive(:delete).and_wrap_original do |original, key|
      delete_attempts += 1
      raise IOError, 'temporary storage failure' if delete_attempts == 1

      original.call(key)
    end

    expect do
      described_class.new(audience_import: audience_import).perform
    end.to raise_error(IOError, 'temporary storage failure')
    expect(audience_import.reload.import_file).to be_attached
    expect(ActiveStorage::Blob.where(id: blob.id)).to exist

    described_class.new(audience_import: audience_import).perform

    expect(audience_import.reload.import_file).not_to be_attached
    expect(ActiveStorage::Blob.where(id: blob.id)).not_to exist
    expect(ActiveStorage::PurgeJob).not_to have_been_enqueued
  end

  it 'purges an orphaned source by attachment id after an inbox cascade' do
    audience_import = create(:campaign_audience_import)
    attach_source(audience_import)
    attachment_id = audience_import.import_file.attachment.id
    blob_id = audience_import.import_file.blob.id
    key = audience_import.import_file.blob.key

    audience_import.inbox.destroy!
    described_class.new(attachment_id: attachment_id).perform

    expect(ActiveStorage::Attachment.where(id: attachment_id)).not_to exist
    expect(ActiveStorage::Blob.where(id: blob_id)).not_to exist
    expect(ActiveStorage::Blob.service).not_to exist(key)
  end

  it 'retains orphan metadata after a storage error and purges it on retry' do
    audience_import = create(:campaign_audience_import)
    attach_source(audience_import)
    attachment_id = audience_import.import_file.attachment.id
    blob = audience_import.import_file.blob
    delete_attempts = 0
    allow(blob.service).to receive(:delete).and_wrap_original do |original, key|
      delete_attempts += 1
      raise IOError, 'temporary storage failure' if delete_attempts == 1

      original.call(key)
    end

    audience_import.inbox.destroy!

    expect do
      described_class.new(attachment_id: attachment_id).perform
    end.to raise_error(IOError, 'temporary storage failure')
    expect(ActiveStorage::Attachment.where(id: attachment_id)).to exist
    expect(ActiveStorage::Blob.where(id: blob.id)).to exist

    described_class.new(attachment_id: attachment_id).perform

    expect(ActiveStorage::Attachment.where(id: attachment_id)).not_to exist
    expect(ActiveStorage::Blob.where(id: blob.id)).not_to exist
  end

  it 'removes only the source attachment when its blob is shared' do
    first_import = create(:campaign_audience_import)
    second_import = create(:campaign_audience_import)
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("phone_number\n87051234567\n"),
      filename: 'recipients.csv',
      content_type: 'text/csv'
    )
    attach_source(first_import, blob)
    attach_source(second_import, blob)
    first_attachment_id = first_import.import_file.attachment.id

    described_class.new(audience_import: first_import).perform

    expect(ActiveStorage::Attachment.where(id: first_attachment_id)).not_to exist
    expect(second_import.reload.import_file).to be_attached
    expect(ActiveStorage::Blob.where(id: blob.id)).to exist
    expect(ActiveStorage::Blob.service).to exist(blob.key)
  end

  it 'is idempotent for missing attachment metadata and an already-missing object' do
    expect { described_class.new(attachment_id: -1).perform }.not_to raise_error

    audience_import = create(:campaign_audience_import)
    attach_source(audience_import)
    attachment_id = audience_import.import_file.attachment.id
    blob = audience_import.import_file.blob
    blob.service.delete(blob.key)

    expect { described_class.new(attachment_id: attachment_id).perform }.not_to raise_error
    expect(ActiveStorage::Attachment.where(id: attachment_id)).not_to exist
    expect(ActiveStorage::Blob.where(id: blob.id)).not_to exist
  end

  it 'is safe when duplicate workers race for the same attachment' do
    audience_import = create(:campaign_audience_import)
    attach_source(audience_import)
    attachment_id = audience_import.import_file.attachment.id
    blob_id = audience_import.import_file.blob.id
    key = audience_import.import_file.blob.key
    barrier = Concurrent::CyclicBarrier.new(2)
    errors = Concurrent::Array.new

    threads = Array.new(2) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier.wait
          described_class.new(attachment_id: attachment_id).perform
        rescue StandardError => e
          errors << e
        end
      end
    end
    threads.each(&:join)

    expect(errors).to be_empty
    expect(ActiveStorage::Attachment.where(id: attachment_id)).not_to exist
    expect(ActiveStorage::Blob.where(id: blob_id)).not_to exist
    expect(ActiveStorage::Blob.service).not_to exist(key)
  end
end
