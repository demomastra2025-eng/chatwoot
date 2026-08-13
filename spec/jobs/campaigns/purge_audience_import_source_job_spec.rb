require 'rails_helper'

RSpec.describe Campaigns::PurgeAudienceImportSourceJob do
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

  it 'does not purge a pending import source' do
    audience_import = create(:campaign_audience_import, status: :pending)
    attach_source(audience_import)

    described_class.perform_now(audience_import.id)

    expect(audience_import.reload.import_file).to be_attached
  end

  it 'purges a terminal import source and tolerates duplicate delivery' do
    audience_import = create(:campaign_audience_import, status: :completed)
    attach_source(audience_import)
    blob_id = audience_import.import_file.blob.id
    key = audience_import.import_file.blob.key

    expect { described_class.perform_now(audience_import.id) }.not_to raise_error
    expect { described_class.perform_now(audience_import.id) }.not_to raise_error

    expect(audience_import.reload.import_file).not_to be_attached
    expect(ActiveStorage::Blob.where(id: blob_id)).not_to exist
    expect(ActiveStorage::Blob.service).not_to exist(key)
  end

  it 'tolerates an import deleted before the job runs' do
    expect { described_class.perform_now(-1) }.not_to raise_error
  end
end
