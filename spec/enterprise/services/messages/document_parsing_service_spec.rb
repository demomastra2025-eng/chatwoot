# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Messages::DocumentParsingService, type: :service do
  let(:account) do
    create(
      :account,
      captain_runtime: {
        'web_document_parse_enabled' => true,
        'web_document_parse_max_chars' => 12_000
      }
    )
  end
  let(:conversation) { create(:conversation, account: account) }
  let(:message) { create(:message, conversation: conversation, content: nil) }
  let(:firecrawl_service) { instance_double(Captain::Tools::FirecrawlService) }

  before do
    account.enable_features('captain_integration')
  end

  describe '#perform' do
    context 'with a Firecrawl-supported document' do
      let(:attachment) do
        message.attachments.create!(
          account: account,
          file_type: :file,
          file: fixture_file_upload('sample.pdf', 'application/pdf')
        )
      end

      before do
        allow(Captain::Tools::FirecrawlService).to receive(:configured?).and_return(true)
        allow(Captain::Tools::FirecrawlService).to receive(:new).and_return(firecrawl_service)
        allow(firecrawl_service).to receive(:parse_upload).and_return(
          double(
            success?: true,
            parsed_response: {
              'success' => true,
              'data' => {
                'markdown' => '## Contract\n\nPayment terms',
                'metadata' => { 'title' => 'Contract' }
              }
            }
          )
        )
      end

      it 'stores parsed text in attachment metadata for Captain and search' do
        result = described_class.new(attachment).perform

        expect(result).to include(success: true, text: '## Contract\n\nPayment terms')
        expect(firecrawl_service).to have_received(:parse_upload).with(
          attachment.file.blob,
          hash_including(formats: ['markdown'], only_main_content: true)
        )

        attachment.reload
        expect(attachment.meta['transcribed_text']).to eq('## Contract\n\nPayment terms')
        expect(attachment.meta['parsed_text']).to eq('## Contract\n\nPayment terms')
        expect(attachment.meta.dig('document_parse', 'status')).to eq('completed')
        expect(attachment.meta.dig('document_parse', 'provider')).to eq('firecrawl')
      end
    end

    context 'with a plain text document' do
      let(:attachment) do
        message.attachments.create!(
          account: account,
          file_type: :file,
          file: {
            io: StringIO.new('plain customer notes'),
            filename: 'notes.txt',
            content_type: 'text/plain'
          }
        )
      end

      before do
        allow(Captain::Tools::FirecrawlService).to receive(:configured?).and_return(false)
      end

      it 'extracts text locally without requiring Firecrawl' do
        result = described_class.new(attachment).perform

        expect(result).to include(success: true, text: 'plain customer notes')
        expect(attachment.reload.meta['parsed_text']).to eq('plain customer notes')
        expect(attachment.meta.dig('document_parse', 'provider')).to eq('local_text')
      end
    end

    context 'when Captain integration is disabled' do
      let(:attachment) do
        message.attachments.create!(
          account: account,
          file_type: :file,
          file: fixture_file_upload('sample.pdf', 'application/pdf')
        )
      end

      before do
        account.disable_features!('captain_integration')
      end

      it 'does not parse or call Firecrawl' do
        expect(Captain::Tools::FirecrawlService).not_to receive(:new)

        result = described_class.new(attachment).perform

        expect(result).to eq(error: 'Document parsing disabled')
        expect(attachment.reload.meta.dig('document_parse', 'status')).to eq('disabled')
      end
    end

    context 'when the document exceeds the effective upload limit' do
      let(:attachment) do
        message.attachments.create!(
          account: account,
          file_type: :file,
          file: fixture_file_upload('sample.pdf', 'application/pdf')
        )
      end

      before do
        allow(Captain::Tools::FirecrawlService).to receive(:configured?).and_return(true)
        allow(Llm::RuntimePolicy).to receive(:web_document_parse_max_file_bytes).and_return(1)
      end

      it 'skips parsing before calling Firecrawl' do
        expect(Captain::Tools::FirecrawlService).not_to receive(:new)

        result = described_class.new(attachment).perform

        expect(result).to eq(error: 'Document parsing too_large')
        expect(attachment.reload.meta.dig('document_parse', 'status')).to eq('too_large')
      end
    end
  end

  describe '.pending_attachment?' do
    let(:attachment) do
      message.attachments.create!(
        account: account,
        file_type: :file,
        file: fixture_file_upload('sample.pdf', 'application/pdf')
      )
    end

    it 'returns false after document text has been stored' do
      allow(Captain::Tools::FirecrawlService).to receive(:configured?).and_return(true)
      expect(described_class.pending_attachment?(attachment, account: account)).to be(true)

      attachment.update!(meta: { 'parsed_text' => 'already parsed' })

      expect(described_class.pending_attachment?(attachment, account: account)).to be(false)
    end
  end
end
