require 'rails_helper'

RSpec.describe Whatsapp::TemplateMediaCleanupJob do
  it 'purges an abandoned upload' do
    attachments = instance_double(ActiveRecord::Associations::CollectionProxy, exists?: false)
    blob = instance_double(ActiveStorage::Blob, attachments: attachments)
    allow(ActiveStorage::Blob).to receive(:find_by).with(id: 42).and_return(blob)
    expect(blob).to receive(:purge)

    described_class.perform_now(42)
  end

  it 'keeps an upload retained by a template media source' do
    attachments = instance_double(ActiveRecord::Associations::CollectionProxy, exists?: true)
    blob = instance_double(ActiveStorage::Blob, attachments: attachments)
    allow(ActiveStorage::Blob).to receive(:find_by).with(id: 42).and_return(blob)
    expect(blob).not_to receive(:purge)

    described_class.perform_now(42)
  end
end
