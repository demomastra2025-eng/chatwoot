require 'rails_helper'

RSpec.describe CampaignAudienceImport do
  include ActiveJob::TestHelper

  self.use_transactional_tests = false

  %i[account inbox].each do |parent_kind|
    it "cleans a claimed import when its #{parent_kind} is destroyed", :aggregate_failures do
      records = create_claimed_graph(parent_kind)
      ids = record_ids(records)
      blob_key = records.fetch(:audience_import).import_file.blob.key

      expect { records.fetch(parent_kind).destroy! }.not_to raise_error

      expect(described_class.where(id: ids.fetch(:audience_import))).not_to exist
      expect(Campaign.find(ids.fetch(:campaign)).campaign_audience_import_id).to be_nil
      expect(ActiveStorage::Attachment.where(id: ids.fetch(:attachment))).to exist
      expect(ActiveStorage::Blob.where(id: ids.fetch(:blob))).to exist
      expect(ActiveStorage::Blob.service).to exist(blob_key)

      Campaigns::AudienceImportCleanupJob.perform_now

      expect(ActiveStorage::Attachment.where(id: ids.fetch(:attachment))).not_to exist
      expect(ActiveStorage::Blob.where(id: ids.fetch(:blob))).not_to exist
      expect(ActiveStorage::Blob.service).not_to exist(blob_key)

      destroy_campaign_async(parent_kind, ids)

      expect(Campaign.where(id: ids.fetch(:campaign))).not_to exist
    ensure
      cleanup_graph(ids, blob_key) if defined?(ids) && ids
    end
  end

  def create_claimed_graph(parent_kind)
    account = create(:account)
    channel = create_sms_channel(account)
    inbox = channel.inbox
    creator = create(:user, account: account, role: :administrator)
    audience_import = create_claimed_import(parent_kind, account, inbox, creator)
    attach_source(audience_import)
    campaign = create_claimed_campaign(account, inbox, audience_import)
    { account: account, channel: channel, inbox: inbox, creator: creator, audience_import: audience_import, campaign: campaign }
  end

  def create_sms_channel(account)
    create(
      :channel_sms,
      account: account,
      phone_number: "+1555#{SecureRandom.random_number(10**10).to_s.rjust(10, '0')}"
    )
  end

  def create_claimed_import(parent_kind, account, inbox, creator)
    create(
      :campaign_audience_import,
      account: account,
      inbox: inbox,
      created_by: creator,
      status: :completed,
      claimed_at: Time.current,
      token: SecureRandom.uuid,
      source_filename: "claimed-#{parent_kind}-cascade.csv"
    )
  end

  def attach_source(audience_import)
    audience_import.import_file.attach(
      io: StringIO.new("phone_number\n87051234567\n"),
      filename: audience_import.source_filename,
      content_type: 'text/csv'
    )
  end

  def create_claimed_campaign(account, inbox, audience_import)
    create(
      :campaign,
      account: account,
      inbox: inbox,
      campaign_type: :one_off,
      campaign_audience_import: audience_import
    )
  end

  def record_ids(records)
    {
      account: records.fetch(:account).id,
      channel: records.fetch(:channel).id,
      inbox: records.fetch(:inbox).id,
      creator: records.fetch(:creator).id,
      audience_import: records.fetch(:audience_import).id,
      campaign: records.fetch(:campaign).id,
      attachment: records.fetch(:audience_import).import_file.attachment.id,
      blob: records.fetch(:audience_import).import_file.blob.id
    }
  end

  def destroy_campaign_async(parent_kind, ids)
    ActiveRecord::DestroyAssociationAsyncJob.perform_now(
      owner_model_name: parent_kind.to_s.classify,
      owner_id: ids.fetch(parent_kind),
      association_class: 'Campaign',
      association_ids: [ids.fetch(:campaign)],
      association_primary_key_column: 'id',
      ensuring_owner_was_method: nil
    )
  end

  def cleanup_graph(ids, blob_key)
    cleanup_source(ids, blob_key)
    cleanup_domain_records(ids)
    clear_enqueued_jobs
  end

  def cleanup_source(ids, blob_key)
    attachment = ActiveStorage::Attachment.find_by(id: ids.fetch(:attachment))
    Campaigns::AudienceImportSourcePurgeService.new(attachment_id: attachment.id).perform if attachment
    ActiveStorage::Blob.service.delete(blob_key) if ActiveStorage::Blob.service.exist?(blob_key)
    ActiveStorage::Blob.where(id: ids.fetch(:blob)).delete_all
  end

  def cleanup_domain_records(ids)
    Campaign.where(id: ids.fetch(:campaign)).delete_all
    CampaignAudienceImport.where(id: ids.fetch(:audience_import)).delete_all
    Inbox.where(id: ids.fetch(:inbox)).delete_all
    Channel::Sms.where(id: ids.fetch(:channel)).delete_all
    Account.where(id: ids.fetch(:account)).delete_all
    User.where(id: ids.fetch(:creator)).destroy_all
  end
end
