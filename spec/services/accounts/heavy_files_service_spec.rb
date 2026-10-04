# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Accounts::HeavyFilesService do
  let(:account) { create(:account) }

  describe '#perform' do
    it 'returns empty array when account has no files' do
      service = described_class.new(account: account)
      expect(service.perform).to eq([])
    end

    it 'clamps limit parameter within allowed bounds' do
      service_low = described_class.new(account: account, params: { limit: -5 })
      expect(service_low.send(:limit)).to eq(1)

      service_high = described_class.new(account: account, params: { limit: 500 })
      expect(service_high.send(:limit)).to eq(100)
    end

    context 'with attachments' do
      let(:message) { create(:message, account: account) }

      def attach(name, bytes)
        attachment = message.attachments.new(account_id: account.id, file_type: :file)
        attachment.file.attach(io: StringIO.new('x' * bytes), filename: name, content_type: 'application/pdf')
        attachment.save!
        attachment
      end

      it 'links every file through its signed blob id so the download works' do
        attachment = attach('report.pdf', 2048)

        file = described_class.new(account: account).perform.first

        expect(file).to include(id: "attachment_#{attachment.id}", name: I18n.t('storage_management.item_labels.file'), byte_size: 2048)
        signed_id = file[:download_url][%r{/blobs/redirect/([^/]+)/report\.pdf}, 1]
        expect(ActiveStorage::Blob.find_signed!(signed_id)).to eq(attachment.file.blob)
      end

      it 'leaves out files that are already in the trash' do
        attach('live.pdf', 100)
        trashed = attach('trashed.pdf', 5000)
        trashed.update!(meta: { 'trash' => { 'bytes' => 5000, 'expires_at' => 5.days.from_now.iso8601 } })

        expect(described_class.new(account: account).perform.pluck(:name)).to eq([I18n.t('storage_management.item_labels.file')])
      end
    end
  end
end
