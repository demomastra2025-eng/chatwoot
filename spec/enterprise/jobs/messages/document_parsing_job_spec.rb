# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Messages::DocumentParsingJob do
  subject(:job) { described_class.perform_later(attachment_id) }

  let(:account) { create(:account, captain_runtime: { 'web_document_parse_enabled' => true }) }
  let(:conversation) { create(:conversation, account: account) }
  let(:message) { create(:message, conversation: conversation) }
  let(:attachment) do
    message.attachments.create!(
      account: account,
      file_type: :file,
      file: fixture_file_upload('sample.pdf', 'application/pdf')
    )
  end
  let(:attachment_id) { attachment.id }
  let(:document_service) { instance_double(Messages::DocumentParsingService) }

  before do
    account.enable_features('captain_integration')
  end

  it 'enqueues the job on the attachment text extraction queue' do
    expect { job }.to have_enqueued_job(described_class)
      .with(attachment_id)
      .on_queue('audio_transcription')
  end

  context 'when performing the job' do
    before do
      allow(Messages::DocumentParsingService).to receive(:new).with(attachment).and_return(document_service)
      allow(document_service).to receive(:perform)
    end

    it 'calls DocumentParsingService with the attachment' do
      expect(Messages::DocumentParsingService).to receive(:new).with(attachment)
      expect(document_service).to receive(:perform)
      described_class.perform_now(attachment_id)
    end

    it 'does nothing when attachment is not found' do
      expect(Messages::DocumentParsingService).not_to receive(:new)
      described_class.perform_now(999_999)
    end
  end
end
