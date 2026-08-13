require 'rails_helper'

RSpec.describe Campaigns::AudienceImportCleanupJob do
  def attach_source(audience_import)
    audience_import.import_file.attach(
      io: StringIO.new("phone_number\n87051234567\n"),
      filename: 'recipients.csv',
      content_type: 'text/csv'
    )
  end

  it 'uses the housekeeping queue' do
    expect(described_class.queue_name).to eq('housekeeping')
  end

  it 'purges and deletes expired unclaimed imports without deleting created contacts' do
    audience_import = create(:campaign_audience_import, expires_at: 1.minute.ago, status: :completed)
    contact = create(:contact, account: audience_import.account, phone_number: '+77051234567')
    create(
      :campaign_audience_recipient,
      campaign_audience_import: audience_import,
      account: audience_import.account,
      contact: contact,
      contact_created: true,
      normalized_phone_number: contact.phone_number
    )
    audience_import.import_file.attach(
      io: StringIO.new("phone_number\n87051234567\n"),
      filename: 'recipients.csv',
      content_type: 'text/csv'
    )
    blob_id = audience_import.import_file.blob_id

    described_class.perform_now

    expect(CampaignAudienceImport.where(id: audience_import.id)).not_to exist
    expect(ActiveStorage::Blob.where(id: blob_id)).not_to exist
    expect(Contact.where(id: contact.id)).to exist
  end

  it 'retains claimed snapshots while they are linked to a campaign' do
    audience_import = create(
      :campaign_audience_import,
      expires_at: 1.minute.ago,
      claimed_at: 2.minutes.ago,
      status: :completed
    )
    create(
      :campaign,
      account: audience_import.account,
      inbox: audience_import.inbox,
      campaign_type: :one_off,
      campaign_audience_import: audience_import
    )

    described_class.perform_now
    described_class.perform_now(audience_import.id)

    expect(CampaignAudienceImport.where(id: audience_import.id)).to exist
  end

  it 'removes a claimed snapshot after its campaign is deleted', :aggregate_failures do
    audience_import = create(
      :campaign_audience_import,
      expires_at: 1.hour.from_now,
      claimed_at: 2.minutes.ago,
      status: :completed
    )
    phone_number = "+1555#{SecureRandom.random_number(10**10).to_s.rjust(10, '0')}"
    contact = create(:contact, account: audience_import.account, phone_number: phone_number)
    create(
      :campaign_audience_recipient,
      campaign_audience_import: audience_import,
      account: audience_import.account,
      contact: contact,
      normalized_phone_number: contact.phone_number
    )
    attach_source(audience_import)
    blob_id = audience_import.import_file.blob.id
    key = audience_import.import_file.blob.key
    campaign = create(
      :campaign,
      account: audience_import.account,
      inbox: audience_import.inbox,
      campaign_type: :one_off,
      campaign_audience_import: audience_import
    )

    expect { campaign.destroy! }
      .to have_enqueued_job(described_class).with(audience_import.id)

    described_class.perform_now(audience_import.id)

    expect(CampaignAudienceImport.where(id: audience_import.id)).not_to exist
    expect(CampaignAudienceRecipient.where(campaign_audience_import_id: audience_import.id)).not_to exist
    expect(ActiveStorage::Blob.where(id: blob_id)).not_to exist
    expect(ActiveStorage::Blob.service).not_to exist(key)
    expect(Contact.where(id: contact.id)).to exist
  end

  it 'reconciles an expired snapshot when targeted cleanup enqueue fails' do
    audience_import = create(
      :campaign_audience_import,
      expires_at: 1.minute.ago,
      claimed_at: 2.minutes.ago,
      status: :completed
    )
    campaign = create(
      :campaign,
      account: audience_import.account,
      inbox: audience_import.inbox,
      campaign_type: :one_off,
      campaign_audience_import: audience_import
    )
    allow(described_class).to receive(:perform_later).and_raise(StandardError, 'queue unavailable')
    allow(Rails.logger).to receive(:error)

    expect { campaign.destroy! }.not_to raise_error

    described_class.perform_now

    expect(CampaignAudienceImport.where(id: audience_import.id)).not_to exist
  end

  it 'reconciles source-file purging for claimed terminal imports' do
    audience_import = create(
      :campaign_audience_import,
      expires_at: 1.minute.ago,
      claimed_at: 2.minutes.ago,
      status: :completed
    )
    audience_import.import_file.attach(
      io: StringIO.new("phone_number\n87051234567\n"),
      filename: 'recipients.csv',
      content_type: 'text/csv'
    )
    create(
      :campaign,
      account: audience_import.account,
      inbox: audience_import.inbox,
      campaign_type: :one_off,
      campaign_audience_import: audience_import
    )

    described_class.perform_now

    expect(Campaigns::PurgeAudienceImportSourceJob).to have_been_enqueued.with(audience_import.id)
    expect(audience_import.reload.import_file).to be_attached

    Campaigns::PurgeAudienceImportSourceJob.perform_now(audience_import.id)

    expect(audience_import.reload.import_file).not_to be_attached
    expect(CampaignAudienceImport.where(id: audience_import.id)).to exist
  end

  it 'purges source metadata and storage left by an inbox cascade' do
    audience_import = create(:campaign_audience_import)
    attach_source(audience_import)
    attachment_id = audience_import.import_file.attachment.id
    blob_id = audience_import.import_file.blob.id
    key = audience_import.import_file.blob.key

    audience_import.inbox.destroy!
    described_class.perform_now

    expect(ActiveStorage::Attachment.where(id: attachment_id)).not_to exist
    expect(ActiveStorage::Blob.where(id: blob_id)).not_to exist
    expect(ActiveStorage::Blob.service).not_to exist(key)
  end

  it 'purges source metadata and storage left by an account cascade' do
    audience_import = create(:campaign_audience_import)
    attach_source(audience_import)
    attachment_id = audience_import.import_file.attachment.id
    blob_id = audience_import.import_file.blob.id
    key = audience_import.import_file.blob.key

    audience_import.account.destroy!
    described_class.perform_now

    expect(ActiveStorage::Attachment.where(id: attachment_id)).not_to exist
    expect(ActiveStorage::Blob.where(id: blob_id)).not_to exist
    expect(ActiveStorage::Blob.service).not_to exist(key)
  end
end
