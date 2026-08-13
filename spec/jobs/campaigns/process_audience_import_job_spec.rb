require 'rails_helper'

RSpec.describe Campaigns::ProcessAudienceImportJob do
  let(:audience_import) { create(:campaign_audience_import, status: :pending) }

  it 'uses the housekeeping queue' do
    expect(described_class.queue_name).to eq('housekeeping')
  end

  it 'processes the import and enqueues source-file purging' do
    audience_import.import_file.attach(
      io: StringIO.new("phone_number,name\n87051234567,Recipient\n"),
      filename: 'recipients.csv',
      content_type: 'text/csv'
    )

    described_class.perform_now(audience_import)

    expect(audience_import.reload).to be_completed
    expect(audience_import.recipient_count).to eq(1)
    expect(Campaigns::PurgeAudienceImportSourceJob).to have_been_enqueued.with(audience_import.id)

    Campaigns::PurgeAudienceImportSourceJob.perform_now(audience_import.id)

    expect(audience_import.import_file).not_to be_attached
  end

  it 'persists a safe failure code and enqueues invalid source-file purging' do
    audience_import.import_file.attach(
      io: StringIO.new("name,email\nNo phone,none@example.com\n"),
      filename: 'recipients.csv',
      content_type: 'text/csv'
    )

    described_class.perform_now(audience_import)

    expect(audience_import.reload).to be_failed
    expect(audience_import.processing_error).to eq('phone_column_required')
    expect(Campaigns::PurgeAudienceImportSourceJob).to have_been_enqueued.with(audience_import.id)

    Campaigns::PurgeAudienceImportSourceJob.perform_now(audience_import.id)

    expect(audience_import.import_file).not_to be_attached
  end

  it 'rechecks completed state while holding the import row lock' do
    service = instance_spy(Campaigns::AudienceImportService)
    allow(Campaigns::AudienceImportService).to receive(:new).and_return(service)
    expect(audience_import).to receive(:with_lock).and_yield do
      audience_import.status = :completed
    end

    described_class.perform_now(audience_import)

    expect(service).not_to have_received(:perform)
  end

  it 'does not retry a terminal failed import after a duplicate delivery' do
    audience_import.update!(status: :failed, processing_error: 'processing_failed')

    expect(Campaigns::AudienceImportService).not_to receive(:new)

    described_class.perform_now(audience_import)
  end

  it 'transitions only active imports to failed' do
    expect(described_class.transition_to_failed(audience_import, error_code: 'processing_failed')).to be(true)
    expect(audience_import.reload).to be_failed
    expect(audience_import.processing_error).to eq('processing_failed')

    processing_import = create(:campaign_audience_import, status: :processing)
    expect(described_class.transition_to_failed(processing_import, error_code: 'processing_failed')).to be(true)
    expect(processing_import.reload).to be_failed
  end

  it 'preserves terminal imports and their error details' do
    audience_import.update!(status: :completed)
    expect(described_class.transition_to_failed(audience_import, error_code: 'processing_failed')).to be(false)
    expect(audience_import.reload).to be_completed
    expect(audience_import.processing_error).to be_nil

    failed_import = create(:campaign_audience_import, status: :failed, processing_error: 'phone_column_required')
    expect(described_class.transition_to_failed(failed_import, error_code: 'processing_failed')).to be(false)
    expect(failed_import.reload).to be_failed
    expect(failed_import.processing_error).to eq('phone_column_required')
  end

  it 'enqueues source purging only after terminal state is committed' do
    audience_import.import_file.attach(
      io: StringIO.new("phone_number\n87051234567\n"),
      filename: 'recipients.csv',
      content_type: 'text/csv'
    )
    audience_import.status = :completed

    described_class.enqueue_source_purge(audience_import)

    expect(audience_import.reload).to be_pending
    expect(audience_import.import_file).to be_attached
    expect(Campaigns::PurgeAudienceImportSourceJob).not_to have_been_enqueued
  end

  it 'reconciles the source attachment on a duplicate delivery for a terminal claimed import' do
    audience_import.update!(status: :completed, claimed_at: Time.current)
    audience_import.import_file.attach(
      io: StringIO.new("phone_number\n87051234567\n"),
      filename: 'recipients.csv',
      content_type: 'text/csv'
    )

    expect(Campaigns::AudienceImportService).not_to receive(:new)

    described_class.perform_now(audience_import)

    expect(Campaigns::PurgeAudienceImportSourceJob).to have_been_enqueued.with(audience_import.id)
  end
end
