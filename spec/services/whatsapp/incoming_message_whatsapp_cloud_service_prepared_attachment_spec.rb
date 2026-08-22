require 'rails_helper'

RSpec.describe Whatsapp::IncomingMessageWhatsappCloudService do
  it 'uses the prepared file without a second provider request' do
    file = Tempfile.new(['prepared-whatsapp-media', '.jpg'])
    prepared = instance_double(Whatsapp::CloudMediaDownload, matches?: true, file: file)
    inbox = instance_double(Inbox)
    service = described_class.new(
      inbox: inbox,
      params: {}.with_indifferent_access,
      prepared_attachment: prepared
    )
    expect(HTTParty).not_to receive(:get)

    result = service.send(:download_attachment_file, { id: 'media-1' }.with_indifferent_access)

    expect(result).to eq(file)
  ensure
    file&.close!
  end

  it 'fails closed instead of downloading under the live webhook lock when the prepared media mismatches' do
    prepared = instance_double(Whatsapp::CloudMediaDownload, matches?: false, file: nil)
    service = described_class.new(
      inbox: instance_double(Inbox),
      params: {}.with_indifferent_access,
      prepared_attachment: prepared,
      require_prepared_attachment: true
    )
    expect(Whatsapp::CloudMediaDownload).not_to receive(:prepare)

    expect do
      service.send(:download_attachment_file, { id: 'other-media' }.with_indifferent_access)
    end.to raise_error(described_class::PreparedAttachmentError, 'Prepared WhatsApp media did not match the attachment')
  end

  it 'fails closed instead of downloading under the live webhook lock when prepared media is missing' do
    service = described_class.new(
      inbox: instance_double(Inbox),
      params: {}.with_indifferent_access,
      require_prepared_attachment: true
    )
    expect(Whatsapp::CloudMediaDownload).not_to receive(:prepare)

    expect do
      service.send(:download_attachment_file, { id: 'media-1' }.with_indifferent_access)
    end.to raise_error(
      described_class::PreparedAttachmentError,
      'Prepared WhatsApp media is required for live webhook dispatch'
    )
  end

  it 'routes non-live history fallback through the bounded media coordinator' do
    file = Tempfile.new(['history-whatsapp-media', '.jpg'])
    download = instance_double(
      Whatsapp::CloudMediaDownload,
      download!: nil,
      matches?: true,
      file: file
    )
    channel = instance_double(Channel::Whatsapp)
    inbox = instance_double(Inbox, channel: channel)
    params = { entry: [] }.with_indifferent_access
    service = described_class.new(inbox: inbox, params: params, outgoing_echo: true)
    expect(Whatsapp::CloudMediaDownload).to receive(:prepare).with(
      channel: channel,
      params: params,
      outgoing_echo: true
    ).and_return(download)

    expect(service.send(:download_attachment_file, { id: 'media-1' }.with_indifferent_access)).to eq(file)
    expect(download).to have_received(:download!)
  ensure
    file&.close!
  end
end
