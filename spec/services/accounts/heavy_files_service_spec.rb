# frozen_string_literal: true

require 'rails_helper'
require 'fileutils'

RSpec.describe Accounts::HeavyFilesService do
  include_context 'with isolated recording storage'

  let(:account) { create(:account) }

  before { Redis::Alfred.delete("account:#{account.id}:storage_heavy_recordings_v1") }

  after { Redis::Alfred.delete("account:#{account.id}:storage_heavy_recordings_v1") }

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

    it 'sets a ten-second attachment statement timeout and restores the previous session value' do
      statements = []
      subscriber = ->(*, payload) { statements << payload[:sql] }
      connection = ActiveRecord::Base.connection
      timeout_before = connection.select_value('SHOW statement_timeout')

      ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
        described_class.new(account: account, params: { file_type: 'documents' }).perform
      end

      expect(statements).to include("SET statement_timeout = '10s'")
      expect(statements.grep(/\ABEGIN\b/)).to be_empty
      expect(connection.select_value('SHOW statement_timeout')).to eq(timeout_before)
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

    context 'with a refreshed recording snapshot' do
      let(:inbox) { create(:inbox, account: account) }
      let(:number_binding) { create(:telephony_number_binding, account: account, inbox: inbox) }

      def recording(size:, created_at:)
        conversation = create(:conversation, account: account, inbox: inbox)
        path = Storage::RecordingPaths.root.join('voice-recordings', 'fixture', account.id.to_s, "#{size}.wav")
        FileUtils.mkdir_p(path.dirname)
        File.write(path, 'r' * size)
        session = create(:telephony_call_session, account: account, inbox: inbox, conversation: conversation,
                                                  number_binding: number_binding,
                                                  recording_ref: path.relative_path_from(Storage::RecordingPaths.root).to_s,
                                                  created_at: created_at)
        [session, path]
      end

      it 'uses the existing stat pass for exact sizes and filters snapshot rows without resolving paths in the request' do
        old_session, old_path = recording(size: 7, created_at: Time.zone.local(2026, 9, 1))
        new_session, new_path = recording(size: 11, created_at: Time.zone.local(2026, 10, 1))
        Accounts::StorageBreakdownRefreshJob.perform_now(account.id)

        snapshot = Accounts::HeavyRecordingsSnapshot.new(account_id: account.id).snapshot
        expect(snapshot[:recordings].map { |row| [row[:id], row[:byte_size]] }).to eq(
          [["call_#{new_session.id}", File.size(new_path)], ["call_#{old_session.id}", File.size(old_path)]]
        )

        expect(Storage::RecordingPaths).not_to receive(:resolve)
        params = {
          file_type: 'recordings', inbox_id: inbox.id, conversation_id: new_session.conversation_id,
          date_from: '2026-10-01', date_to: '2026-10-01', limit: 1
        }
        files = described_class.new(account: account, params: params).perform

        expect(files.map { |row| [row[:id], row[:byte_size]] }).to eq([["call_#{new_session.id}", File.size(new_path)]])
        expect(files.first).to include(file_type: 'recording', inbox_id: inbox.id, conversation_id: new_session.conversation_id)
      end
    end
  end
end
