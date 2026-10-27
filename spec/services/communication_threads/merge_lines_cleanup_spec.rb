# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'

# The activity lines that the one-dialog merge wrote into the conversations ("Объединено: звонок из канала «…»"): the dry run, the
# delete with its backup, and the restore.
RSpec.describe CommunicationThreads::MergeLinesCleanup do
  let(:out) { StringIO.new }
  let(:cleanup) { described_class.new(out: out) }
  let(:backup_dir) { Dir.mktmpdir('merge-lines') }
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:other_conversation) { create(:conversation, account: other_account) }

  # The way the old merge wrote them: an activity message without a sender, the id of the merged conversation in the attributes.
  def merge_line(conversation, content, created_at: Time.utc(2026, 10, 27, 8, 15, 30, 123_456))
    conversation.messages.create!(
      account_id: conversation.account_id, inbox_id: conversation.inbox_id, message_type: :activity, content: content,
      additional_attributes: { 'single_open_dialog_merged_conversation_id' => 1 }, created_at: created_at
    )
  end

  def lines_in_output
    out.string.lines.map { |line| JSON.parse(line) if line.start_with?('{') }.compact
  end

  after { FileUtils.remove_entry(backup_dir) }

  describe '.scope' do
    it 'matches both lines in the three languages whatever the channel is called', :aggregate_failures do
      lines = [
        'Объединено: звонок из канала «Sipuni»', 'Объединено: диалог из канала «WhatsApp 100%_вер "Б" »»»',
        'Merged: call from channel "Phone"', 'Merged: dialog from channel "WA web"',
        'Біріктірілді: «Қоңырау» арнасынан қоңырау', 'Біріктірілді: «Telegram» арнасынан диалог'
      ].map { |content| merge_line(conversation, content) }

      expect(described_class.scope.pluck(:id)).to match_array(lines.map(&:id))
    end

    it 'leaves every other message alone, the activity lines of other changes and the same text in a message too', :aggregate_failures do
      merge_line(conversation, 'Объединено: звонок из канала «Sipuni»')
      other = [
        conversation.messages.create!(account_id: account.id, inbox_id: conversation.inbox_id, message_type: :activity,
                                      content: 'Диалог был решен с Иваном из-за бездействия'),
        conversation.messages.create!(account_id: account.id, inbox_id: conversation.inbox_id, message_type: :activity,
                                      content: 'Объединено: звонок'),
        conversation.messages.create!(account_id: account.id, inbox_id: conversation.inbox_id, message_type: :activity,
                                      content: 'Заметка. Объединено: звонок из канала «Sipuni»'),
        conversation.messages.create!(account_id: account.id, inbox_id: conversation.inbox_id, message_type: :incoming,
                                      content: 'Объединено: диалог из канала «Sipuni»'),
        conversation.messages.create!(account_id: account.id, inbox_id: conversation.inbox_id, message_type: :outgoing,
                                      content: 'Merged: call from channel "Phone"', private: true)
      ]

      expect(described_class.scope.count).to eq(1)
      expect(Message.where(id: other.map(&:id)).count).to eq(other.size)
    end
  end

  describe '#report' do
    before do
      merge_line(conversation, 'Объединено: звонок из канала «Sipuni»', created_at: Time.utc(2026, 10, 26, 10, 0, 0))
      merge_line(conversation, 'Объединено: диалог из канала «WhatsApp»')
      merge_line(other_conversation, 'Merged: call from channel "Phone"')
    end

    it 'counts per account and writes nothing', :aggregate_failures do
      expect { cleanup.report }.not_to(change { Message.unscoped.pluck(:id, :content, :updated_at) })

      expect(lines_in_output).to eq(
        [
          { 'account_id' => account.id, 'messages' => 2, 'conversations' => 1,
            'first_created_at' => '2026-10-26T10:00:00Z', 'last_created_at' => '2026-10-27T08:15:30Z' },
          { 'account_id' => other_account.id, 'messages' => 1, 'conversations' => 1,
            'first_created_at' => '2026-10-27T08:15:30Z', 'last_created_at' => '2026-10-27T08:15:30Z' },
          { 'mode' => 'dry_run', 'messages' => 3, 'accounts' => 2 }
        ]
      )
      expect(out.string).to include('DRY RUN: nothing was written.')
    end
  end

  describe '#delete' do
    let!(:lines) do
      [merge_line(conversation, 'Объединено: звонок из канала «Sipuni»'), merge_line(conversation, 'Merged: dialog from channel "WA"'),
       merge_line(other_conversation, 'Біріктірілді: «Telegram» арнасынан диалог')]
    end
    let!(:kept) do
      [conversation.messages.create!(account_id: account.id, inbox_id: conversation.inbox_id, message_type: :activity,
                                     content: 'Диалог был открыт с Иваном'),
       create(:message, conversation: conversation, content: 'Здравствуйте')]
    end

    it 'refuses without a backup directory and deletes nothing', :aggregate_failures do
      expect { cleanup.delete(backup_dir: '') }.to raise_error(described_class::Refused, /BACKUP_DIR/)

      expect(described_class.scope.count).to eq(3)
    end

    it 'writes a backup of every column, then deletes only the lines', :aggregate_failures do
      summary = cleanup.delete(backup_dir: backup_dir)

      expect(summary).to include(mode: 'applied', messages: 3, deleted: 3)
      expect(described_class.scope.count).to eq(0)
      expect(Message.where(id: kept.map(&:id)).count).to eq(2)
      expect(Conversation.where(id: [conversation.id, other_conversation.id]).count).to eq(2)

      backup = JSON.parse(File.read(summary[:backup]))
      expect(File.dirname(summary[:backup])).to eq(backup_dir)
      expect(backup).to include('format' => 'onelink_merge_lines_backup', 'version' => 1, 'count' => 3)
      expect(backup['messages'].pluck('id')).to eq(lines.map(&:id))
      expect(backup['messages'].first).to include(
        'id' => lines.first.id, 'account_id' => account.id, 'conversation_id' => conversation.id, 'message_type' => 'activity',
        'content' => 'Объединено: звонок из канала «Sipuni»', 'content_attributes' => {}, 'created_at' => '2026-10-27T08:15:30.123456Z',
        'additional_attributes' => { 'single_open_dialog_merged_conversation_id' => 1 }
      )
    end

    it 'finds nothing on the second run and writes no backup for it', :aggregate_failures do
      cleanup.delete(backup_dir: backup_dir)
      second = described_class.new(out: StringIO.new)

      expect(second.report).to include(messages: 0, accounts: 0)
      expect(second.delete(backup_dir: backup_dir)).to include(deleted: 0, backup: nil)
      expect(Dir.children(backup_dir).size).to eq(1)
    end

    it 'deletes nothing when the backup cannot be written', :aggregate_failures do
      blocked = File.join(backup_dir, 'not-a-directory')
      File.write(blocked, 'x')

      expect { cleanup.delete(backup_dir: blocked) }.to raise_error(SystemCallError)

      expect(described_class.scope.count).to eq(3)
    end

    it 'deletes nothing when the lines are changed while it runs', :aggregate_failures do
      allow(Message).to receive(:transaction).and_wrap_original do |original, *args, &block|
        Message.where(id: lines.last.id).delete_all
        original.call(*args, &block)
      end

      expect { cleanup.delete(backup_dir: backup_dir) }.to raise_error(described_class::Refused, /nothing was deleted/)

      expect(described_class.scope.count).to eq(2)
    end

    it 'dispatches no event' do
      allow(Rails.configuration.dispatcher).to receive(:dispatch)

      cleanup.delete(backup_dir: backup_dir)

      expect(Rails.configuration.dispatcher).not_to have_received(:dispatch)
    end
  end

  describe '#restore' do
    let!(:lines) do
      [merge_line(conversation, 'Объединено: звонок из канала «Sipuni»'), merge_line(conversation, 'Merged: dialog from channel "WA"'),
       merge_line(other_conversation, 'Біріктірілді: «Telegram» арнасынан диалог')]
    end
    let(:backup_file) { cleanup.delete(backup_dir: backup_dir)[:backup] }
    let(:restore_cleanup) { described_class.new(out: out) }

    def snapshot
      Message.unscoped.where(id: lines.map(&:id)).order(:id).map do |message|
        message.attributes.transform_values { |value| value.respond_to?(:iso8601) ? value.utc.iso8601(6) : value }
      end
    end

    it 'is a dry run unless asked, and says what it would put back', :aggregate_failures do
      backup_file

      summary = restore_cleanup.restore(backup_file, apply: false)

      expect(summary).to include(mode: 'restore_dry_run', in_file: 3, to_restore: 3, restored: 0, already_present: 0, conversation_missing: 0)
      expect(Message.unscoped.where(id: lines.map(&:id))).to be_empty
      expect(out.string).to include('DRY RUN: nothing was written.')
    end

    it 'puts the lines back as they were, with their ids, and does it only once', :aggregate_failures do
      before = snapshot
      backup_file

      summary = restore_cleanup.restore(backup_file, apply: true)

      expect(summary).to include(mode: 'restored', to_restore: 3, restored: 3)
      expect(snapshot).to eq(before)
      expect(described_class.scope.count).to eq(3)
      expect(restore_cleanup.restore(backup_file, apply: true)).to include(to_restore: 0, restored: 0, already_present: 3)
      expect(described_class.scope.count).to eq(3)
    end

    it 'skips the lines of a conversation that is gone', :aggregate_failures do
      backup_file
      other_conversation.destroy!

      summary = restore_cleanup.restore(backup_file, apply: true)

      expect(summary).to include(restored: 2, conversation_missing: 1)
      expect(Message.unscoped.where(id: lines.map(&:id)).pluck(:id)).to match_array(lines.first(2).map(&:id))
    end

    it 'refuses a file that is missing, damaged or not a backup', :aggregate_failures do
      damaged = File.join(backup_dir, 'damaged.json')
      File.write(damaged, '{"format":"onelink_merge_lines_backup","version":1,"count":2,"messages":[]}')
      other = File.join(backup_dir, 'other.json')
      File.write(other, '{"format":"something else"}')
      incoming = File.join(backup_dir, 'incoming.json')
      File.write(incoming, JSON.generate(format: 'onelink_merge_lines_backup', version: 1, count: 1,
                                         messages: [{ id: 1, account_id: 1, inbox_id: 1, conversation_id: 1, message_type: 'incoming',
                                                      created_at: '2026-10-27T00:00:00Z', updated_at: '2026-10-27T00:00:00Z' }]))

      [File.join(backup_dir, 'missing.json'), damaged, other, incoming].each do |file|
        expect { restore_cleanup.restore(file, apply: true) }.to raise_error(described_class::Refused)
      end
    end
  end
end
