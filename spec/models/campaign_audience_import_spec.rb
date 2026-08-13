require 'rails_helper'

RSpec.describe CampaignAudienceImport do
  def attach_source(audience_import)
    audience_import.import_file.attach(
      io: StringIO.new("phone_number\n87051234567\n"),
      filename: 'recipients.csv',
      content_type: 'text/csv'
    )
  end

  it 'fails closed when directly destroyed before its source is safely purged' do
    audience_import = create(:campaign_audience_import)
    attach_source(audience_import)
    attachment_id = audience_import.import_file.attachment.id
    blob_id = audience_import.import_file.blob.id
    key = audience_import.import_file.blob.key

    expect { audience_import.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)

    expect(described_class.where(id: audience_import.id)).to exist
    expect(ActiveStorage::Attachment.where(id: attachment_id)).to exist
    expect(ActiveStorage::Blob.where(id: blob_id)).to exist
    expect(ActiveStorage::Blob.service).to exist(key)
  end

  it 'can be destroyed after object-first source purging' do
    audience_import = create(:campaign_audience_import)
    attach_source(audience_import)
    key = audience_import.import_file.blob.key

    Campaigns::AudienceImportSourcePurgeService.new(audience_import: audience_import).perform

    expect { audience_import.destroy! }.not_to raise_error
    expect(described_class.where(id: audience_import.id)).not_to exist
    expect(ActiveStorage::Blob.service).not_to exist(key)
  end
end
