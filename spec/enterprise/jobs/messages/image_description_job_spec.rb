# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Messages::ImageDescriptionJob do
  let(:account) { create(:account) }
  let(:message) { create(:message, account: account) }
  let(:attachment) { message.attachments.create!(account_id: account.id, file_type: :image, external_url: 'https://example.com/photo.jpg') }
  let(:service) { instance_double(Messages::ImageDescriptionService, perform: nil) }

  before { allow(Messages::ImageDescriptionService).to receive(:new).with(attachment).and_return(service) }

  it 'is queued with the document parsing, which every AI worker works' do
    expect { described_class.perform_later(attachment.id) }
      .to have_enqueued_job(described_class).with(attachment.id).on_queue('audio_transcription')
  end

  it 'describes the image of the attachment' do
    described_class.perform_now(attachment.id)

    expect(service).to have_received(:perform)
  end

  it 'ignores an attachment that is gone' do
    expect { described_class.perform_now(0) }.not_to raise_error
    expect(Messages::ImageDescriptionService).not_to have_received(:new)
  end

  it 'tries again a little later when the file is not attached yet' do
    allow(service).to receive(:perform).and_raise(Messages::ImageDescriptionService::NotReady)

    expect { described_class.perform_now(attachment.id) }.to have_enqueued_job(described_class).with(attachment.id)
  end

  it 'leaves the image to the run that needs it when the file never comes, without an error' do
    allow(service).to receive(:perform).and_raise(Messages::ImageDescriptionService::NotReady)

    perform_enqueued_jobs do
      expect { described_class.perform_later(attachment.id) }.not_to raise_error
    end
    expect(service).to have_received(:perform).exactly(4).times
  end
end
