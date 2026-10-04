# frozen_string_literal: true

require 'rails_helper'
require 'fileutils'

RSpec.describe Storage::TrashService, type: :service do
  let(:account) { create(:account) }
  let(:service) { described_class.new(account: account) }
  let(:storage_dir) { Rails.root.join('storage', 'voice-recordings', 'test_trash', account.id.to_s) }
  let(:storage_test_cache) { ActiveSupport::Cache::MemoryStore.new }

  def approved_move_to_trash!(**)
    preview = service.preview(**)
    service.move_to_trash!(**, preview_token: preview[:confirmation_token], confirmed: true)
  end

  before do
    allow(Rails).to receive(:cache).and_return(storage_test_cache)
    FileUtils.mkdir_p(storage_dir)
  end

  after do
    FileUtils.rm_rf(storage_dir)
    FileUtils.rm_rf(Rails.root.join('storage', 'trash', account.id.to_s))
  end

  describe '#preview' do
    it 'returns preview data for recordings and attachments' do
      test_file = storage_dir.join('call_1.mp3')
      File.write(test_file, 'sample audio data' * 100)

      session = create(
        :telephony_call_session,
        account: account,
        recording_ref: "voice-recordings/test_trash/#{account.id}/call_1.mp3",
        created_at: 7.months.ago
      )

      res = service.preview(older_than_months: 6)

      expect(res).to include(total_count: 1, recordings_count: 1)
      expect(res[:total_bytes]).to be > 0
      expect(res[:samples].first[:id]).to eq(session.id)
    end
  end

  describe '#move_to_trash! and #restore!' do
    let(:test_file) { storage_dir.join('call_2.mp3') }
    let!(:session) do
      File.write(test_file, 'sample call recording data')
      create(
        :telephony_call_session,
        account: account,
        recording_ref: "voice-recordings/test_trash/#{account.id}/call_2.mp3",
        created_at: 4.months.ago
      )
    end

    it 'moves recording to trash folder' do
      move_res = approved_move_to_trash!(older_than_months: 3)

      expect(move_res).to include(success: true, moved_count: 1)
      expect(move_res[:freed_bytes]).to eq(0)
      expect(move_res[:pending_bytes]).to be > 0
      expect(File.exist?(test_file)).to be(false)
      expect(File.exist?(session.reload.metadata.dig('trash', 'trash_path'))).to be(true)

      session.reload
      expect(session.recording_ref).to be_nil
      expect(session.metadata['trash']).to be_present
      expect(File.exist?(session.metadata.dig('trash', 'trash_path'))).to be(true)
    end

    it 'restores recording back from trash' do
      approved_move_to_trash!(older_than_months: 3)
      session.reload

      restore_res = service.restore!(item_type: 'recording', item_id: session.id)
      expect(restore_res).to include(success: true, restored_count: 1)

      session.reload
      expect(session.recording_ref).to eq("voice-recordings/test_trash/#{account.id}/call_2.mp3")
      expect(session.metadata['trash']).to be_nil
      expect(File.exist?(test_file)).to be(true)
    end

    it 'lists items in trash with days remaining' do
      approved_move_to_trash!(older_than_months: 3)

      trash_list = service.list_trash
      expect(trash_list).to include(total_count: 1)
      expect(trash_list[:items].first).to include(id: session.id)
      expect(trash_list[:items].first[:days_remaining]).to be > 0
    end
  end

  describe '#empty_trash!' do
    it 'permanently purges items from disk and marks session purged' do
      test_file = storage_dir.join('call_3.mp3')
      File.write(test_file, 'audio to be permanently purged')

      session = create(
        :telephony_call_session,
        account: account,
        recording_ref: "voice-recordings/test_trash/#{account.id}/call_3.mp3",
        created_at: 4.months.ago
      )

      approved_move_to_trash!(older_than_months: 3)
      session.reload
      trash_file = session.metadata.dig('trash', 'trash_path')

      empty_res = service.empty_trash!(purge_all: true)
      expect(empty_res).to include(success: true, purged_count: 1)
      expect(File.exist?(trash_file)).to be(false)

      session.reload
      expect(session.metadata['trash']).to be_nil
      expect(session.metadata.dig('recording', 'purged')).to be(true)
    end
  end

  describe '.purge_expired_all!' do
    it 'purges only expired items older than 30 days' do
      test_file1 = storage_dir.join('expired.mp3')
      File.write(test_file1, 'expired audio')
      trash_dir = Rails.root.join('storage', 'trash', account.id.to_s, 'recordings')
      FileUtils.mkdir_p(trash_dir)
      trash_path1 = trash_dir.join('1_expired.mp3')
      FileUtils.mv(test_file1, trash_path1)

      expired_session = create(
        :telephony_call_session,
        account: account,
        recording_ref: nil,
        metadata: {
          'trash' => {
            'deleted_at' => 35.days.ago.iso8601,
            'expires_at' => 5.days.ago.iso8601,
            'trash_path' => trash_path1.to_s,
            'bytes' => 100
          }
        }
      )

      test_file2 = storage_dir.join('active.mp3')
      File.write(test_file2, 'active audio in trash')
      trash_path2 = trash_dir.join('2_active.mp3')
      FileUtils.mv(test_file2, trash_path2)

      active_trash_session = create(
        :telephony_call_session,
        account: account,
        recording_ref: nil,
        metadata: {
          'trash' => {
            'deleted_at' => 5.days.ago.iso8601,
            'expires_at' => 25.days.from_now.iso8601,
            'trash_path' => trash_path2.to_s,
            'bytes' => 100
          }
        }
      )

      res = described_class.purge_expired_all!

      expect(res[:purged_count]).to eq(1)
      expect(File.exist?(trash_path1)).to be(false)
      expect(File.exist?(trash_path2)).to be(true)

      expired_session.reload
      expect(expired_session.metadata['trash']).to be_nil
      expect(expired_session.metadata.dig('recording', 'purged')).to be(true)

      active_trash_session.reload
      expect(active_trash_session.metadata['trash']).to be_present
    end
  end

  describe 'cleanup parameters' do
    it 'refuses a missing, zero or malformed age instead of trashing everything' do
      [nil, 0, '0', -3, 'abc'].each do |months|
        expect { service.move_to_trash!(older_than_months: months) }.to raise_error(described_class::InvalidParams)
        expect { service.preview(older_than_months: months) }.to raise_error(described_class::InvalidParams)
      end
    end

    it 'accepts the age as a numeric string, like the API passes it' do
      expect(approved_move_to_trash!(older_than_months: '6')).to include(success: true, moved_count: 0)
    end
  end

  describe 'cleanup confirmation binding' do
    it 'rejects a preview token when a different admin attempts to redeem it' do
      admin_preview = described_class.new(account: account, actor_id: 101)
      other_admin = described_class.new(account: account, actor_id: 202)
      preview = admin_preview.preview(older_than_months: 6)

      expect do
        other_admin.move_to_trash!(
          older_than_months: 6, preview_token: preview[:confirmation_token], confirmed: true
        )
      end.to raise_error(described_class::InvalidParams)
    end

    it 'rejects a same-sized replacement item instead of selecting the new row' do
      file = storage_dir.join('same-size.mp3')
      File.write(file, 'exactly same physical bytes')
      original = create(
        :telephony_call_session, account: account,
                                 recording_ref: "voice-recordings/test_trash/#{account.id}/same-size.mp3",
                                 created_at: 8.months.ago
      )
      preview = service.preview(older_than_months: 6)
      original_attributes = { account: account, recording_ref: original.recording_ref, created_at: original.created_at }
      original.destroy!
      replacement = create(:telephony_call_session, **original_attributes)

      expect do
        service.move_to_trash!(
          older_than_months: 6, preview_token: preview[:confirmation_token], confirmed: true
        )
      end.to raise_error(described_class::InvalidParams)
      expect(File.exist?(file)).to be(true)
      expect(replacement.reload.recording_ref).to eq(original_attributes[:recording_ref])
      expect(replacement.metadata['trash']).to be_nil
    end
  end

  describe 'recordings that are not ours to move' do
    it 'leaves provider-hosted references untouched' do
      session = create(:telephony_call_session, account: account, recording_ref: 'https://provider.example/rec/1.wav',
                                                created_at: 8.months.ago)

      expect(service.preview(older_than_months: 6)).to include(recordings_count: 0)
      expect(approved_move_to_trash!(older_than_months: 6)).to include(moved_count: 0)
      expect(session.reload.recording_ref).to eq('https://provider.example/rec/1.wav')
      expect(session.metadata['trash']).to be_nil
    end

    it 'never reaches files outside of the storage folder' do
      outside = Rails.root.join('tmp', "outside_#{account.id}.wav")
      FileUtils.mkdir_p(outside.dirname)
      File.write(outside, 'not a recording')
      session = create(:telephony_call_session, account: account, recording_ref: "../tmp/outside_#{account.id}.wav",
                                                created_at: 8.months.ago)

      expect(approved_move_to_trash!(older_than_months: 6)).to include(moved_count: 0)
      expect(File.exist?(outside)).to be(true)
      expect(session.reload.recording_ref).to eq("../tmp/outside_#{account.id}.wav")
    ensure
      FileUtils.rm_f(outside)
    end

    it 'puts the file back when the call session cannot be updated' do
      file = storage_dir.join('call_rollback.mp3')
      File.write(file, 'audio')
      create(:telephony_call_session, account: account, recording_ref: "voice-recordings/test_trash/#{account.id}/call_rollback.mp3",
                                      created_at: 8.months.ago)
      allow_any_instance_of(Telephony::CallSession).to receive(:save!).and_raise(ActiveRecord::StatementInvalid, 'boom') # rubocop:disable RSpec/AnyInstance

      expect(approved_move_to_trash!(older_than_months: 6)).to include(moved_count: 0)
      expect(File.exist?(file)).to be(true)
    end
  end

  describe 'trash metadata is not trusted blindly' do
    it 'does not delete a file outside of the trash folder when purging' do
      victim = storage_dir.join('victim.txt')
      File.write(victim, 'keep me')
      session = create(:telephony_call_session, account: account, recording_ref: nil,
                                                metadata: { 'trash' => { 'trash_path' => victim.to_s, 'bytes' => 7,
                                                                         'expires_at' => 1.day.ago.iso8601 } })

      expect(described_class.purge_expired_all!).to include(purged_count: 0, failed_count: 1)
      expect(File.exist?(victim)).to be(true)
      expect(session.reload.metadata['trash']).to be_present
    end

    it 'does not point a call back at a file that is gone from the trash' do
      session = create(:telephony_call_session, account: account, recording_ref: nil,
                                                metadata: { 'trash' => { 'trash_path' => storage_dir.join('gone.mp3').to_s,
                                                                         'original_path' => storage_dir.join('gone.mp3').to_s,
                                                                         'original_recording_ref' => 'voice-recordings/gone.mp3',
                                                                         'bytes' => 10, 'expires_at' => 5.days.from_now.iso8601 } })

      expect(service.restore!(item_type: 'recording', item_id: session.id)).to include(restored_count: 0)
      expect(session.reload.recording_ref).to be_nil
      expect(session.metadata['trash']).to be_present
    end
  end

  describe 'recording lifecycle safety' do
    it 'keeps transcript and call metadata after an explicit purge' do
      file = storage_dir.join('transcript.mp3')
      File.write(file, 'recording bytes')
      session = create(:telephony_call_session, account: account,
                                                recording_ref: "voice-recordings/test_trash/#{account.id}/transcript.mp3",
                                                created_at: 8.months.ago,
                                                metadata: { 'transcript' => 'call transcript', 'recording' => { 'duration_seconds' => 42 } })
      move_result = approved_move_to_trash!(older_than_months: 6)
      expect(move_result[:freed_bytes]).to eq(0)

      service.empty_trash!(item_type: 'recording', item_id: session.id)

      session.reload
      expect(session.metadata['transcript']).to eq('call transcript')
      expect(session.metadata.dig('recording', 'duration_seconds')).to eq(42)
      expect(session.metadata.dig('recording', 'purged')).to be(true)
    end

    it 'preserves the transcript and restores owner playback references' do
      file = storage_dir.join('message-recording.mp3')
      File.write(file, 'recording for transcript')
      key = "voice-recordings/test_trash/#{account.id}/message-recording.mp3"
      session = create(:telephony_call_session, account: account, recording_ref: key, created_at: 8.months.ago)
      conversation = session.conversation || create(:conversation, account: account, inbox: session.inbox)
      session.update!(conversation: conversation, inbox: conversation.inbox)
      conversation.update!(additional_attributes: { 'recording' => { 'storage_key' => key } })
      message = create(:message, account: account, conversation: conversation, inbox: conversation.inbox,
                                 content_attributes: { 'data' => { 'recording_ref' => key, 'recording_url' => '/signed',
                                                                   'recording' => { 'storage_key' => key }, 'transcript' => 'keep words' },
                                                       'other' => { 'keep' => true } })

      approved_move_to_trash!(older_than_months: 6)

      expect(message.reload.content_attributes.dig('data', 'transcript')).to eq('keep words')
      expect(message.content_attributes.dig('data', 'recording', 'status')).to eq('trashed')
      expect(message.content_attributes.dig('data', 'recording', 'storage_key')).to be_nil
      expect(conversation.reload.additional_attributes.dig('recording', 'status')).to eq('trashed')

      service.restore!(item_type: 'recording', item_id: session.id)

      expect(message.reload.content_attributes.dig('data', 'recording', 'storage_key')).to eq(key)
      expect(message.content_attributes.dig('data', 'transcript')).to eq('keep words')
      expect(conversation.reload.additional_attributes.dig('recording', 'storage_key')).to eq(key)
    end

    it 'trashes and restores an absolute session reference with its qualified message alias' do
      file = storage_dir.join('absolute-recording.mp3')
      File.write(file, 'absolute recording')
      relative_key = "voice-recordings/test_trash/#{account.id}/absolute-recording.mp3"
      session = create(
        :telephony_call_session, account: account, recording_ref: file.to_s, created_at: 8.months.ago
      )
      conversation = session.conversation || create(:conversation, account: account, inbox: session.inbox)
      session.update!(conversation: conversation, inbox: conversation.inbox)
      message = create(
        :message, account: account, conversation: conversation, inbox: conversation.inbox,
                   content_attributes: { 'data' => { 'recording_ref' => relative_key, 'transcript' => 'preserve absolute owner' } }
      )

      expect(approved_move_to_trash!(older_than_months: 6)[:moved_count]).to eq(1)
      expect(message.reload.content_attributes.dig('data', 'recording_ref')).to be_nil

      service.restore!(item_type: 'recording', item_id: session.id)

      expect(session.reload.recording_ref).to eq(file.to_s)
      expect(message.reload.content_attributes.dig('data', 'recording_ref')).to eq(relative_key)
      expect(message.content_attributes.dig('data', 'transcript')).to eq('preserve absolute owner')
      expect(File.exist?(file)).to be(true)
    end

    it 'restores only the manifest references for one recording in a shared conversation' do
      conversation = create(:conversation, account: account)
      key_a = "voice-recordings/test_trash/#{account.id}/shared-a.mp3"
      key_b = "voice-recordings/test_trash/#{account.id}/shared-b.mp3"
      file_a = storage_dir.join('shared-a.mp3')
      file_b = storage_dir.join('shared-b.mp3')
      File.write(file_a, 'recording A')
      File.write(file_b, 'recording B')
      number_binding = create(:telephony_number_binding, account: account, inbox: conversation.inbox)
      call_a = create(
        :telephony_call_session, account: account, conversation: conversation, inbox: conversation.inbox,
                                 number_binding: number_binding,
                                 recording_ref: key_a, created_at: 8.months.ago
      )
      call_b = create(
        :telephony_call_session, account: account, conversation: conversation, inbox: conversation.inbox,
                                 number_binding: number_binding, recording_ref: key_b, created_at: 8.months.ago
      )
      message_a = create(
        :message, account: account, conversation: conversation, inbox: conversation.inbox,
                   content_attributes: { 'data' => { 'recording_ref' => key_a, 'recording' => { 'storage_key' => key_a },
                                                     'transcript' => 'transcript A' } }
      )
      message_b = create(
        :message, account: account, conversation: conversation, inbox: conversation.inbox,
                   content_attributes: { 'data' => { 'recording_ref' => key_b, 'recording' => { 'storage_key' => key_b },
                                                     'transcript' => 'transcript B' } }
      )

      result = approved_move_to_trash!(older_than_months: 6)

      expect(result[:moved_count]).to eq(2)
      expect(message_a.reload.content_attributes.dig('data', 'recording', 'status')).to eq('trashed')
      expect(message_b.reload.content_attributes.dig('data', 'recording', 'status')).to eq('trashed')
      service.restore!(item_type: 'recording', item_id: call_a.id)

      expect(message_a.reload.content_attributes.dig('data', 'recording_ref')).to eq(key_a)
      expect(message_a.content_attributes.dig('data', 'recording', 'storage_key')).to eq(key_a)
      expect(message_a.content_attributes.dig('data', 'transcript')).to eq('transcript A')
      expect(message_b.reload.content_attributes.dig('data', 'recording_ref')).to be_nil
      expect(message_b.content_attributes.dig('data', 'recording', 'storage_key')).to be_nil
      expect(message_b.content_attributes.dig('data', 'recording', 'status')).to eq('trashed')
      expect(message_b.content_attributes.dig('data', 'transcript')).to eq('transcript B')

      service.restore!(item_type: 'recording', item_id: call_b.id)

      expect(message_b.reload.content_attributes.dig('data', 'recording_ref')).to eq(key_b)
      expect(message_b.content_attributes.dig('data', 'recording', 'storage_key')).to eq(key_b)
      expect(File.exist?(file_a)).to be(true)
      expect(File.exist?(file_b)).to be(true)
    end

    it 'rolls the file back into trash when restore metadata persistence fails' do
      file = storage_dir.join('restore-rollback.mp3')
      File.write(file, 'rollback fixture')
      key = "voice-recordings/test_trash/#{account.id}/restore-rollback.mp3"
      session = create(:telephony_call_session, account: account, recording_ref: key, created_at: 8.months.ago)
      approved_move_to_trash!(older_than_months: 6)
      trash_path = session.reload.metadata.dig('trash', 'trash_path')

      allow(Telephony::CallSession).to receive(:find_by)
        .with(id: session.id, account_id: account.id)
        .and_return(session)
      allow(session).to receive(:save!)
        .and_raise(ActiveRecord::StatementInvalid, 'synthetic persistence failure')
      advisory_lock_active = false
      row_lock_active = false
      allow(Storage::RecordingLock).to receive(:synchronize).and_wrap_original do |original, **args, &operation|
        original.call(**args) do
          advisory_lock_active = true
          begin
            operation.call
          ensure
            advisory_lock_active = false
          end
        end
      end
      allow(session).to receive(:with_lock).and_wrap_original do |original, *args, **kwargs, &operation|
        original.call(*args, **kwargs) do
          row_lock_active = true
          begin
            operation.call
          ensure
            row_lock_active = false
          end
        end
      end
      allow(service).to receive(:rollback_restored_recording_files).and_wrap_original do |original, moved_entries|
        expect(advisory_lock_active).to be(true)
        expect(row_lock_active).to be(true)
        original.call(moved_entries)
      end

      expect { service.restore!(item_type: 'recording', item_id: session.id) }
        .to raise_error(ActiveRecord::StatementInvalid, 'synthetic persistence failure')
      expect(File.exist?(file)).to be(false)
      expect(File.exist?(trash_path)).to be(true)
      expect(session.reload.recording_ref).to be_nil
      expect(session.metadata['trash']).to be_present
    end

    it 'continues restoring rollback entries when one moved file cannot safely return to trash' do
      trash_dir = Storage::RecordingPaths.prepare_trash_directory(account.id)
      original_paths = %w[first second].map { |name| storage_dir.join("rollback-#{name}.mp3") }
      trash_paths = %w[first second].map { |name| trash_dir.join("rollback-#{name}.mp3") }
      original_paths.zip(trash_paths).each_with_index do |(original, trashed), index|
        File.write(original, "rollback audio #{index}")
        FileUtils.mv(original, trashed)
      end
      manifest = original_paths.zip(trash_paths).map.with_index do |(original, trashed), index|
        {
          'storage_key' => "voice-recordings/test_trash/#{account.id}/rollback-#{index}.mp3",
          'original_path' => original.to_s,
          'trash_path' => trashed.to_s
        }
      end
      session = create(
        :telephony_call_session,
        account: account,
        recording_ref: nil,
        metadata: { 'trash' => { 'original_recording_ref' => manifest.first['storage_key'],
                                 'files' => manifest, 'bytes' => 42 } }
      )
      allow(Telephony::CallSession).to receive(:find_by)
        .with(id: session.id, account_id: account.id)
        .and_return(session)
      allow(session).to receive(:save!).and_raise(ActiveRecord::StatementInvalid, 'synthetic persistence failure')
      allow(service).to receive(:move_file_exclusively).and_wrap_original do |original, source, destination|
        raise IOError, 'synthetic rollback failure' if source.to_s == original_paths.second.to_s

        original.call(source, destination)
      end

      expect { service.restore!(item_type: 'recording', item_id: session.id) }
        .to raise_error(ActiveRecord::StatementInvalid, 'synthetic persistence failure')

      expect(File.exist?(original_paths.first)).to be(false)
      expect(File.exist?(trash_paths.first)).to be(true)
      expect(File.exist?(original_paths.second)).to be(true)
      expect(File.exist?(trash_paths.second)).to be(false)
      expect(session.reload.metadata['trash']).to be_present
      expect(session.recording_ref).to be_nil
    end

    it 'restores detached legacy basenames to their original file after a provider collision appears' do
      file = storage_dir.join('legacy-alias.mp3')
      File.write(file, 'legacy recording bytes')
      key = "voice-recordings/test_trash/#{account.id}/legacy-alias.mp3"
      session = create(:telephony_call_session, account: account, recording_ref: key, created_at: 8.months.ago)
      conversation = session.conversation || create(:conversation, account: account, inbox: session.inbox)
      session.update!(conversation: conversation, inbox: conversation.inbox)
      message = create(
        :message, account: account, conversation: conversation, inbox: conversation.inbox,
                   content_attributes: { 'data' => { 'recording_ref' => 'legacy-alias.mp3', 'transcript' => 'keep words' } }
      )
      conversation.update!(additional_attributes: { 'recording_ref' => 'legacy-alias.mp3', 'keep' => true })

      approved_move_to_trash!(older_than_months: 6)

      second_root = Rails.root.join('storage', 'voice-recordings', 'sipuni', account.id.to_s)
      second_path = second_root.join('legacy-alias.mp3')
      FileUtils.mkdir_p(second_root)
      File.write(second_path, 'different provider recording')

      trashed_references = {
        message_reference: message.reload.content_attributes.dig('data', 'recording_ref'),
        message_status: message.content_attributes.dig('data', 'recording', 'status'),
        transcript: message.content_attributes.dig('data', 'transcript'),
        conversation_reference: conversation.reload.additional_attributes['recording_ref'],
        conversation_status: conversation.additional_attributes.dig('recording', 'status'),
        keep: conversation.additional_attributes['keep']
      }
      expect(trashed_references.values).to eq([nil, 'trashed', 'keep words', nil, 'trashed', true])

      service.restore!(item_type: 'recording', item_id: session.id)

      restored_references = {
        message_reference: message.reload.content_attributes.dig('data', 'recording_ref'),
        conversation_reference: conversation.reload.additional_attributes['recording_ref'],
        basename_resolves: Storage::RecordingPaths.resolve('legacy-alias.mp3', account_id: account.id),
        key_matches_original: Storage::RecordingPaths.same_physical_file?(key, file, account_id: account.id),
        key_matches_other: Storage::RecordingPaths.same_physical_file?(key, second_path, account_id: account.id)
      }
      expect(restored_references.values).to eq([key, key, nil, true, false])
    ensure
      FileUtils.rm_rf(second_root) if second_root
    end

    it 'does not move a file while its basename is ambiguous across provider roots' do
      first_path = storage_dir.join('collision.mp3')
      second_root = Rails.root.join('storage', 'voice-recordings', 'sipuni', account.id.to_s)
      second_path = second_root.join('collision.mp3')
      FileUtils.mkdir_p(second_root)
      File.write(first_path, 'first physical recording')
      File.write(second_path, 'second physical recording')

      selected_key = first_path.relative_path_from(Rails.root.join('storage')).to_s
      selected_session = create(
        :telephony_call_session, account: account, recording_ref: selected_key, created_at: 8.months.ago
      )
      conversation = selected_session.conversation || create(
        :conversation, account: account, inbox: selected_session.inbox
      )
      selected_session.update!(conversation: conversation, inbox: conversation.inbox)
      message = create(
        :message, account: account, conversation: conversation, inbox: conversation.inbox,
                   content_attributes: { 'data' => { 'recording_ref' => 'collision.mp3' } }
      )

      result = approved_move_to_trash!(older_than_months: 6)

      expect(result[:moved_count]).to eq(0)
      expect(message.reload.content_attributes.dig('data', 'recording_ref')).to eq('collision.mp3')
      expect(Storage::RecordingPaths.resolve('collision.mp3', account_id: account.id)).to be_nil
      expect(File.exist?(first_path)).to be(true)
      expect(File.exist?(second_path)).to be(true)
    ensure
      FileUtils.rm_rf(second_root) if defined?(second_root)
    end

    it 'uses a qualified reference to keep a different same-name provider file from blocking trash' do
      first_path = storage_dir.join('qualified-collision.mp3')
      second_root = Rails.root.join('storage', 'voice-recordings', 'sipuni', account.id.to_s)
      second_path = second_root.join('qualified-collision.mp3')
      FileUtils.mkdir_p(second_root)
      File.write(first_path, 'selected source recording')
      File.write(second_path, 'other provider recording')

      selected_key = first_path.relative_path_from(Rails.root.join('storage')).to_s
      other_key = second_path.relative_path_from(Rails.root.join('storage')).to_s
      create(:telephony_call_session, account: account, recording_ref: selected_key, created_at: 8.months.ago)
      other_conversation = create(:conversation, account: account)
      message = create(
        :message, account: account, conversation: other_conversation, inbox: other_conversation.inbox,
                   content_attributes: {
                     'data' => { 'recording_ref' => 'qualified-collision.mp3',
                                 'recording' => { 'storage_key' => other_key } }
                   }
      )

      result = approved_move_to_trash!(older_than_months: 6)

      expect(result[:moved_count]).to eq(1)
      expect(File.exist?(first_path)).to be(false)
      expect(File.exist?(second_path)).to be(true)
      expect(message.reload.content_attributes.dig('data', 'recording_ref')).to eq('qualified-collision.mp3')
      expect(message.content_attributes.dig('data', 'recording', 'storage_key')).to eq(other_key)
    ensure
      FileUtils.rm_rf(second_root) if defined?(second_root)
    end

    it 'does not trash a recording referenced by absolute path in another conversation' do
      file = storage_dir.join('absolute-shared.mp3')
      File.write(file, 'shared absolute recording')
      key = "voice-recordings/test_trash/#{account.id}/absolute-shared.mp3"
      session = create(:telephony_call_session, account: account, recording_ref: key, created_at: 8.months.ago)
      conversation = create(:conversation, account: account)
      create(
        :message, account: account, conversation: conversation, inbox: conversation.inbox,
                   content_attributes: { 'data' => { 'recording' => { 'recording_ref' => file.to_s } } }
      )

      expect(approved_move_to_trash!(older_than_months: 6)).to include(moved_count: 0)
      expect(File.exist?(file)).to be(true)
      expect(session.reload.recording_ref).to eq(key)
    end

    it 'does not move a recording referenced by a different conversation' do
      file = storage_dir.join('message-shared.mp3')
      File.write(file, 'shared recording bytes')
      key = "voice-recordings/test_trash/#{account.id}/message-shared.mp3"
      session = create(:telephony_call_session, account: account, recording_ref: key, created_at: 8.months.ago)
      conversation = create(:conversation, account: account)
      create(:message, account: account, conversation: conversation, inbox: conversation.inbox,
                       content_attributes: { 'data' => { 'recording_ref' => key } })

      expect(approved_move_to_trash!(older_than_months: 6)).to include(moved_count: 0)
      expect(File.exist?(file)).to be(true)
      expect(session.reload.recording_ref).to eq(key)
    end

    it 'does not move a recording referenced by the top-level data storage key' do
      file = storage_dir.join('top-level-storage-key.mp3')
      File.write(file, 'shared top-level recording')
      key = "voice-recordings/test_trash/#{account.id}/top-level-storage-key.mp3"
      session = create(:telephony_call_session, account: account, recording_ref: key, created_at: 8.months.ago)
      conversation = create(:conversation, account: account)
      message = create(
        :message, account: account, conversation: conversation, inbox: conversation.inbox,
                   content_attributes: { 'data' => { 'storage_key' => key, 'transcript' => 'preserve transcript' } }
      )

      expect(approved_move_to_trash!(older_than_months: 6)).to include(moved_count: 0)
      expect(File.exist?(file)).to be(true)
      expect(session.reload.recording_ref).to eq(key)
      expect(message.reload.content_attributes.dig('data', 'transcript')).to eq('preserve transcript')
    end

    it 'does not move a recording referenced by a conversation top-level storage key' do
      file = storage_dir.join('conversation-storage-key.mp3')
      File.write(file, 'shared conversation recording')
      key = "voice-recordings/test_trash/#{account.id}/conversation-storage-key.mp3"
      session = create(:telephony_call_session, account: account, recording_ref: key, created_at: 8.months.ago)
      conversation = create(
        :conversation, account: account, additional_attributes: { 'storage_key' => key, 'transcript' => 'keep words' }
      )

      expect(approved_move_to_trash!(older_than_months: 6)).to include(moved_count: 0)
      expect(File.exist?(file)).to be(true)
      expect(session.reload.recording_ref).to eq(key)
      expect(conversation.reload.additional_attributes).to include('storage_key' => key, 'transcript' => 'keep words')
    end

    it 'purges a trashed recording while preserving its transcript' do
      file = storage_dir.join('purge-message.mp3')
      File.write(file, 'audio with transcript')
      key = "voice-recordings/test_trash/#{account.id}/purge-message.mp3"
      session = create(:telephony_call_session, account: account, recording_ref: key, created_at: 8.months.ago)
      conversation = session.conversation || create(:conversation, account: account, inbox: session.inbox)
      session.update!(conversation: conversation, inbox: conversation.inbox)
      message = create(:message, account: account, conversation: conversation, inbox: conversation.inbox,
                                 content_attributes: { 'data' => { 'recording_ref' => key,
                                                                   'recording' => { 'storage_key' => key },
                                                                   'transcript' => 'keep after purge' } })

      approved_move_to_trash!(older_than_months: 6)
      trash_path = session.reload.metadata.dig('trash', 'trash_path')
      service.empty_trash!(item_type: 'recording', item_id: session.id)

      expect(File.exist?(trash_path)).to be(false)
      expect(session.reload.metadata.dig('recording', 'purged')).to be(true)
      expect(message.reload.content_attributes.dig('data', 'transcript')).to eq('keep after purge')
      expect(message.content_attributes.dig('data', 'recording_ref')).to be_nil
    end

    it 'does not move a recording that a newer same-account call still references' do
      file = storage_dir.join('shared-before-trash.mp3')
      File.write(file, 'shared recording bytes')
      key = "voice-recordings/test_trash/#{account.id}/shared-before-trash.mp3"
      old_call = create(:telephony_call_session, account: account, recording_ref: key, created_at: 8.months.ago)
      current_call = create(:telephony_call_session, account: account, recording_ref: key, created_at: 1.day.ago)

      result = approved_move_to_trash!(older_than_months: 6)

      expect(result[:moved_count]).to eq(0)
      expect(File.exist?(file)).to be(true)
      expect(old_call.reload.recording_ref).to eq(key)
      expect(current_call.reload.recording_ref).to eq(key)
      expect(old_call.metadata['trash']).to be_nil
    end

    it 'does not purge a trashed file later referenced through its legacy basename' do
      file = storage_dir.join('purge-alias.mp3')
      File.write(file, 'shared recording bytes')
      key = "voice-recordings/test_trash/#{account.id}/purge-alias.mp3"
      trashed = create(:telephony_call_session, account: account, recording_ref: key, created_at: 8.months.ago)
      approved_move_to_trash!(older_than_months: 6)
      trashed.reload
      trash_path = trashed.metadata.dig('trash', 'trash_path')
      create(:telephony_call_session, account: account, recording_ref: 'purge-alias.mp3')

      result = service.empty_trash!(item_type: 'recording', item_id: trashed.id)

      expect(result[:purged_count]).to eq(0)
      expect(File.exist?(trash_path)).to be(true)
      expect(trashed.reload.metadata['trash']).to be_present
    end

    it 'keeps trash when a post-trash message still points to the qualified original path' do
      file = storage_dir.join('post-trash-reference.mp3')
      File.write(file, 'recording retained by a late message reference')
      key = "voice-recordings/test_trash/#{account.id}/post-trash-reference.mp3"
      trashed = create(:telephony_call_session, account: account, recording_ref: key, created_at: 8.months.ago)

      expect(approved_move_to_trash!(older_than_months: 6)[:moved_count]).to eq(1)
      trashed.reload
      trash_path = trashed.metadata.dig('trash', 'trash_path')
      conversation = create(:conversation, account: account)
      message = create(
        :message, account: account, conversation: conversation, inbox: conversation.inbox,
                   content_attributes: {
                     'data' => { 'recording_ref' => file.to_s, 'transcript' => 'keep transcript' }
                   }
      )

      result = service.empty_trash!(item_type: 'recording', item_id: trashed.id)

      expect(result[:purged_count]).to eq(0)
      expect(File.exist?(trash_path)).to be(true)
      expect(trashed.reload.metadata['trash']).to be_present
      expect(message.reload.content_attributes.dig('data', 'recording_ref')).to eq(file.to_s)
      expect(message.content_attributes.dig('data', 'transcript')).to eq('keep transcript')
    end

    it 'does not purge a file named by another call trash manifest' do
      file = storage_dir.join('manifest-holder.mp3')
      File.write(file, 'retained by another manifest')
      key = "voice-recordings/test_trash/#{account.id}/manifest-holder.mp3"
      trashed = create(:telephony_call_session, account: account, recording_ref: key, created_at: 8.months.ago)
      approved_move_to_trash!(older_than_months: 6)
      trashed.reload
      trash_path = trashed.metadata.dig('trash', 'trash_path')
      create(
        :telephony_call_session,
        account: account,
        recording_ref: "voice-recordings/test_trash/#{account.id}/other-call.mp3",
        metadata: {
          'trash' => {
            'files' => [{
              'storage_key' => key, 'original_path' => file.to_s, 'trash_path' => trash_path
            }]
          }
        }
      )

      result = service.empty_trash!(item_type: 'recording', item_id: trashed.id)

      expect(result[:purged_count]).to eq(0)
      expect(File.exist?(trash_path)).to be(true)
      expect(trashed.reload.metadata['trash']).to be_present
    end

    it 'does not trash a provider-qualified recording referenced through its legacy basename' do
      file = storage_dir.join('shared-alias.mp3')
      File.write(file, 'shared recording bytes')
      full_key = "voice-recordings/test_trash/#{account.id}/shared-alias.mp3"
      old_call = create(:telephony_call_session, account: account, recording_ref: full_key, created_at: 8.months.ago)
      current_call = create(:telephony_call_session, account: account, recording_ref: 'shared-alias.mp3', created_at: 1.day.ago)

      result = approved_move_to_trash!(older_than_months: 6)

      expect(result[:moved_count]).to eq(0)
      expect(File.exist?(file)).to be(true)
      expect(old_call.reload.recording_ref).to eq(full_key)
      expect(current_call.reload.recording_ref).to eq('shared-alias.mp3')
    end

    it 'does not purge trash files while another live call session references the same key' do
      file = storage_dir.join('shared.mp3')
      File.write(file, 'shared recording')
      storage_key = "voice-recordings/test_trash/#{account.id}/shared.mp3"
      trashed = create(:telephony_call_session, account: account, recording_ref: storage_key, created_at: 8.months.ago)
      approved_move_to_trash!(older_than_months: 6)
      trashed.reload
      trash_path = trashed.metadata.dig('trash', 'trash_path')
      create(:telephony_call_session, account: account, recording_ref: storage_key)

      result = service.empty_trash!(item_type: 'recording', item_id: trashed.id)

      expect(result[:purged_count]).to eq(0)
      expect(File.exist?(trash_path)).to be(true)
      expect(trashed.reload.metadata['trash']).to be_present
    end

    it 'does not purge a trashed path retained by another call session' do
      file = storage_dir.join('retained-shared.mp3')
      File.write(file, 'shared recording')
      storage_key = "voice-recordings/test_trash/#{account.id}/retained-shared.mp3"
      trashed = create(:telephony_call_session, account: account, recording_ref: storage_key, created_at: 8.months.ago)
      approved_move_to_trash!(older_than_months: 6)
      trashed.reload
      trash_path = trashed.metadata.dig('trash', 'trash_path')
      create(:telephony_call_session, account: account, recording_ref: "voice-recordings/test_trash/#{account.id}/current.mp3",
                                      metadata: { 'recording' => { 'retained_original' => { 'storage_key' => storage_key } } })

      result = service.empty_trash!(item_type: 'recording', item_id: trashed.id)

      expect(result[:purged_count]).to eq(0)
      expect(File.exist?(trash_path)).to be(true)
      expect(trashed.reload.metadata['trash']).to be_present
    end

    it 'does not purge trash still named by another call current-storage metadata' do
      file = storage_dir.join('current-holder.mp3')
      File.write(file, 'retained by current metadata')
      key = "voice-recordings/test_trash/#{account.id}/current-holder.mp3"
      trashed = create(:telephony_call_session, account: account, recording_ref: key, created_at: 8.months.ago)
      approved_move_to_trash!(older_than_months: 6)
      trash_path = trashed.reload.metadata.dig('trash', 'trash_path')
      create(
        :telephony_call_session, account: account,
                              recording_ref: "voice-recordings/test_trash/#{account.id}/other-current.mp3",
                              metadata: { 'recording' => { 'storage_key' => key } }
      )

      result = service.empty_trash!(item_type: 'recording', item_id: trashed.id)

      expect(result[:purged_count]).to eq(0)
      expect(File.exist?(trash_path)).to be(true)
      expect(trashed.reload.metadata['trash']).to be_present
    end

    it 'cannot restore or purge another account’s trash file' do
      other_account = create(:account)
      other_trash = Rails.root.join('storage', 'trash', other_account.id.to_s, 'recordings')
      FileUtils.mkdir_p(other_trash)
      foreign_file = other_trash.join('foreign.mp3')
      File.write(foreign_file, 'foreign bytes')
      session = create(:telephony_call_session, account: account, recording_ref: nil,
                                                metadata: { 'trash' => {
                                                  'original_recording_ref' => "voice-recordings/janus/#{other_account.id}/foreign.mp3",
                                                  'trash_path' => foreign_file.to_s, 'bytes' => 13,
                                                  'files' => [{ 'storage_key' => "voice-recordings/janus/#{other_account.id}/foreign.mp3", 'trash_path' => foreign_file.to_s }],
                                                  'expires_at' => 5.days.from_now.iso8601
                                                } })

      expect(service.restore!(item_type: 'recording', item_id: session.id)[:restored_count]).to eq(0)
      expect { service.empty_trash!(item_type: 'recording', item_id: session.id) }
        .to raise_error(described_class::InvalidParams)
      expect(File.exist?(foreign_file)).to be(true)
      expect(session.reload.metadata['trash']).to be_present
    ensure
      FileUtils.rm_rf(other_trash) if other_trash
    end
  end

  describe 'attachments' do
    let(:message) { create(:message, account: account) }
    let!(:old_attachment) { create_attachment(created_at: 8.months.ago) }
    let!(:new_attachment) { create_attachment(created_at: 1.day.ago) }

    def create_attachment(created_at:)
      attachment = message.attachments.new(account_id: account.id, file_type: :file)
      attachment.file.attach(io: StringIO.new('x' * 2048), filename: "doc_#{SecureRandom.hex(3)}.pdf", content_type: 'application/pdf')
      attachment.save!
      attachment.update_columns(created_at: created_at) # rubocop:disable Rails/SkipsModelValidations
      attachment
    end

    it 'only flags old attachments and does not claim their quota is freed' do
      result = approved_move_to_trash!(file_type: 'all', older_than_months: 6)

      expect(result).to include(moved_count: 1, moved_bytes: 2048, freed_bytes: 0, pending_bytes: 2048)
      expect(old_attachment.reload.meta['trash']).to be_present
      expect(old_attachment.file).to be_attached
      expect(new_attachment.reload.meta['trash']).to be_nil
    end

    it 'keeps trashed attachments counted in the quota until they are purged' do
      before_bytes = AccountLimits::StorageUsageService.new(account: account).usage_bytes
      approved_move_to_trash!(file_type: 'all', older_than_months: 6)

      expect(AccountLimits::StorageUsageService.new(account: account).usage_bytes).to eq(before_bytes)

      service.empty_trash!(purge_all: true)
      expect(AccountLimits::StorageUsageService.new(account: account).usage_bytes).to eq(before_bytes - 2048)
    end

    it 'refuses to purge an attachment that is not in the trash' do
      expect(service.empty_trash!(item_type: 'attachment', item_id: new_attachment.id)).to include(purged_count: 0)
      expect(Attachment.exists?(new_attachment.id)).to be(true)
      expect(new_attachment.reload.file).to be_attached
    end

    it 'purges a trashed attachment on request and restores another one' do
      approved_move_to_trash!(file_type: 'all', older_than_months: 6)

      expect(service.restore!(item_type: 'attachment', item_id: old_attachment.id)).to include(restored_count: 1)
      expect(old_attachment.reload.meta['trash']).to be_nil

      approved_move_to_trash!(file_type: 'all', older_than_months: 6)
      expect(service.empty_trash!(item_type: 'attachment', item_id: old_attachment.id)).to include(purged_count: 1)
      expect(Attachment.exists?(old_attachment.id)).to be(false)
    end
  end

  describe '.purge_expired_all! failure isolation' do
    it 'keeps going when one item cannot be purged' do
      trash_dir = Rails.root.join('storage', 'trash', account.id.to_s, 'recordings')
      FileUtils.mkdir_p(trash_dir)
      paths = %w[a b].map { |name| trash_dir.join("#{name}.mp3").tap { |path| File.write(path, 'audio') } }
      sessions = paths.map do |path|
        create(:telephony_call_session, account: account, recording_ref: nil,
                                        metadata: { 'trash' => { 'trash_path' => path.to_s, 'bytes' => 5,
                                                                 'expires_at' => 1.day.ago.iso8601 } })
      end
      allow(File).to receive(:delete).and_call_original
      allow(File).to receive(:delete).with(paths.first.to_s).and_raise(Errno::EACCES)

      result = described_class.purge_expired_all!

      expect(result).to include(purged_count: 1, failed_count: 1)
      expect(sessions.last.reload.metadata['trash']).to be_nil
      expect(sessions.first.reload.metadata['trash']).to be_present
    end
  end
end
