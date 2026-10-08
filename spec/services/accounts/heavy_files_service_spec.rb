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
      expect(connection.select_value('SHOW statement_timeout')).to eq(timeout_before)
    end

    it 'runs attachment queries with the existing transaction depth and never opens its own transaction' do
      connection = ActiveRecord::Base.connection
      baseline = connection.open_transactions
      seen = []
      subscriber = lambda do |*, payload|
        seen << connection.open_transactions if payload[:sql].include?('active_storage_blobs')
      end

      ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
        described_class.new(account: account, params: { file_type: 'documents' }).perform
      end

      expect(seen).not_to be_empty
      expect(seen.uniq).to eq([baseline])
    end

    it 'restores the session timeout when an attachment query fails' do
      service = described_class.new(account: account, params: { file_type: 'documents' })
      connection = ActiveRecord::Base.connection
      previous = connection.select_value('SHOW statement_timeout')
      scope = service.send(:filtered_attachment_scope)
      allow(service).to receive(:filtered_attachment_scope).and_return(scope)
      allow(scope).to receive(:order).and_raise(ActiveRecord::QueryCanceled, 'statement timeout')

      expect { service.perform }.to raise_error(Accounts::HeavyFilesService::AttachmentTimeout)
      expect(connection.select_value('SHOW statement_timeout')).to eq(previous)
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
        expect(Storage::RecordingPaths).not_to receive(:each_file_with_stat_for_account)
        params = {
          file_type: 'recordings', inbox_id: inbox.id, conversation_id: new_session.conversation_id,
          date_from: '2026-10-01', date_to: '2026-10-01', limit: 1
        }
        files = described_class.new(account: account, params: params).perform

        expect(files.map { |row| [row[:id], row[:byte_size]] }).to eq([["call_#{new_session.id}", File.size(new_path)]])
        expect(files.first).to include(file_type: 'recording', inbox_id: inbox.id, conversation_id: new_session.conversation_id)
      end

      it 'filters the complete tenant recording set before limiting, including recordings below the global top 200' do
        other_inbox = create(:inbox, account: account)
        target = create(:telephony_call_session, account: account, inbox: inbox, number_binding: number_binding,
                                                 recording_ref: "voice-recordings/fixture/#{account.id}/small.wav",
                                                 created_at: Time.zone.local(2026, 10, 1),
                                                 metadata: { 'recording' => { 'byte_size' => 1 } })
        now = Time.current
        rows = 205.times.map do |index|
          {
            account_id: account.id, inbox_id: other_inbox.id, external_call_ref: "large-#{index}", provider: 'fixture',
            recording_ref: "voice-recordings/fixture/#{account.id}/large-#{index}.wav", status: 'completed', direction: 'inbound',
            metadata: { 'recording' => { 'byte_size' => index + 100 } }, created_at: now, updated_at: now
          }
        end
        Telephony::CallSession.insert_all!(rows)
        expect(Storage::RecordingPaths).not_to receive(:resolve)
        expect(Storage::RecordingPaths).not_to receive(:each_file_with_stat_for_account)
        params = { file_type: 'recordings', inbox_id: inbox.id, conversation_id: target.conversation_id,
                   date_from: '2026-10-01', date_to: '2026-10-01', limit: 1 }
        service = described_class.new(account: account, params: params)

        expect(service.perform.pluck(:id)).to eq(["call_#{target.id}"])
        expect(service.recordings_pending?).to be(false)
      end

      it 'returns measured rows and marks a filtered list incomplete when legacy sizes are missing' do
        known = create(:telephony_call_session, account: account, inbox: inbox, number_binding: number_binding,
                                                recording_ref: "voice-recordings/fixture/#{account.id}/known.wav",
                                                metadata: { 'recording' => { 'byte_size' => 20 } })
        create(:telephony_call_session, account: account, inbox: inbox, number_binding: number_binding,
                                       recording_ref: 'legacy.wav', metadata: { 'recording' => { 'byte_size' => 'broken' } })
        service = described_class.new(account: account, params: { file_type: 'recordings', inbox_id: inbox.id })

        expect { expect(service.perform.pluck(:id)).to eq(["call_#{known.id}"]) }
          .to have_enqueued_job(Accounts::StorageBreakdownRefreshJob).with(account.id)
        expect(service.recordings_pending?).to be(true)
        expect(service.recordings_refresh_status).to eq('queued')
      end

      it 'never includes another account or a foreign tenant path in recording results' do
        foreign = create(:account)
        create(:telephony_call_session, account: foreign,
                                       recording_ref: "voice-recordings/fixture/#{foreign.id}/foreign.wav",
                                       metadata: { 'recording' => { 'byte_size' => 1000 } })
        create(:telephony_call_session, account: account, inbox: inbox, number_binding: number_binding,
                                       recording_ref: "voice-recordings/fixture/#{foreign.id}/foreign.wav",
                                       metadata: { 'recording' => { 'byte_size' => 1000 } })
        service = described_class.new(account: account, params: { file_type: 'recordings' })

        expect(service.perform).to be_empty
        expect(service.recordings_pending?).to be(true)
      end

      it 'accepts numeric date directories under this account while rejecting a numeric foreign account as provider' do
        own = create(:telephony_call_session, account: account, inbox: inbox, number_binding: number_binding,
                                              recording_ref: "voice-recordings/#{account.id}/2026/10/call.wav",
                                              metadata: { 'recording' => { 'byte_size' => 36 } })
        foreign_id = create(:account).id
        create(:telephony_call_session, account: account, inbox: inbox, number_binding: number_binding,
                                       recording_ref: "voice-recordings/#{foreign_id}/#{account.id}/foreign.wav",
                                       metadata: { 'recording' => { 'byte_size' => 1000 } })

        files = described_class.new(account: account, params: { file_type: 'recordings' }).perform

        expect(files.map { |row| [row[:id], row[:byte_size]] }).to eq([["call_#{own.id}", 36]])
      end

      it 'generates the current recording link immediately after compression rather than serving an old snapshot URL' do
        session, = recording(size: 30, created_at: Time.current)
        Accounts::StorageBreakdownRefreshJob.perform_now(account.id)
        old = described_class.new(account: account, params: { file_type: 'recordings' }).perform.sole
        new_key = "voice-recordings/fixture/#{account.id}/compressed.mp3"
        session.update!(recording_ref: new_key, metadata: { 'recording' => { 'storage_key' => new_key, 'byte_size' => 10 } })
        Accounts::StorageOverviewService.new(account: account).invalidate!

        current = described_class.new(account: account, params: { file_type: 'recordings' }).perform.sole

        expect(current[:byte_size]).to eq(10)
        expect(current[:download_url]).not_to eq(old[:download_url])
        token = CGI.parse(URI.parse(current[:download_url]).query)['recording_token'].sole
        expect(Telephony::CallRecordingPlaybackUrl.valid?(token: token, call_session: session, storage_key: new_key)).to be(true)
      end

      it 'reflects a committed trash, restore and purge without waiting for a snapshot refresh' do
        session, = recording(size: 40, created_at: 4.months.ago)
        overview = Accounts::StorageOverviewService.new(account: account)
        overview.refresh!
        trash = Storage::TrashService.new(account: account)
        service = described_class.new(account: account, params: { file_type: 'recordings' })
        move = lambda do
          preview = trash.preview(file_type: 'recordings', older_than_months: 3)
          trash.move_to_trash!(file_type: 'recordings', older_than_months: 3,
                               preview_token: preview[:confirmation_token], confirmed: true)
        end

        move.call
        expect(service.perform).to be_empty
        expect(overview.stale?(overview.snapshot)).to be(true)
        trash.restore!(item_type: 'recording', item_id: session.id)
        expect(service.perform.pluck(:id)).to eq(["call_#{session.id}"])
        move.call
        trash.empty_trash!(item_type: 'recording', item_id: session.id)
        expect(service.perform).to be_empty
      end
    end
  end
end
