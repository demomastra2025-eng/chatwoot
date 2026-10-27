# frozen_string_literal: true

require 'rails_helper'
require 'rake'
require 'tmpdir'

RSpec.describe 'onelink:threads:delete_merge_lines rake task' do # rubocop:disable RSpec/DescribeClass
  let(:task) { Rake::Task['onelink:threads:delete_merge_lines'] }
  let(:backup_dir) { Dir.mktmpdir('merge-lines-rake') }
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:other_conversation) { create(:conversation, account: other_account) }
  let!(:lines) do
    [[conversation, 'Объединено: звонок из канала «Sipuni»'], [conversation, 'Объединено: диалог из канала «WhatsApp»'],
     [other_conversation, 'Merged: dialog from channel "Telegram"']].map do |record, content|
      record.messages.create!(account_id: record.account_id, inbox_id: record.inbox_id, message_type: :activity, content: content,
                              additional_attributes: { 'single_open_dialog_merged_conversation_id' => 1 })
    end
  end
  let!(:other_activity) do
    conversation.messages.create!(account_id: account.id, inbox_id: conversation.inbox_id, message_type: :activity,
                                  content: 'Диалог был открыт с Иваном')
  end

  def run_task(env = {})
    task.reenable
    output = StringIO.new
    $stdout = output
    with_modified_env({ 'APPLY' => nil, 'CONFIRM' => nil, 'BACKUP_DIR' => nil, 'RESTORE' => nil }.merge(env)) { task.invoke }
    output.string
  ensure
    $stdout = STDOUT
  end

  def backup_file
    Dir.glob(File.join(backup_dir, 'merge_lines_backup_*.json')).sole
  end

  before { Rails.application.load_tasks unless Rake::Task.task_defined?('onelink:threads:delete_merge_lines') }

  after { FileUtils.remove_entry(backup_dir) }

  it 'is a dry run by default: the counts per account, nothing deleted', :aggregate_failures do
    output = run_task

    summaries = output.lines.select { |line| line.start_with?('{') }.map { |line| JSON.parse(line) }
    expect(summaries.first(2).map { |row| row.slice('account_id', 'messages', 'conversations') }).to eq(
      [{ 'account_id' => account.id, 'messages' => 2, 'conversations' => 1 },
       { 'account_id' => other_account.id, 'messages' => 1, 'conversations' => 1 }]
    )
    expect(summaries.last).to eq('mode' => 'dry_run', 'messages' => 3, 'accounts' => 2)
    expect(output).to include('DRY RUN: nothing was written.')
    expect(Message.where(id: lines.map(&:id)).count).to eq(3)
    expect(Dir.children(backup_dir)).to be_empty
  end

  it 'stays a dry run for APPLY=0 and for CONFIRM without APPLY', :aggregate_failures do
    expect(run_task('APPLY' => '0', 'CONFIRM' => 'yes', 'BACKUP_DIR' => backup_dir)).to include('DRY RUN')
    expect(run_task('CONFIRM' => 'yes', 'BACKUP_DIR' => backup_dir)).to include('DRY RUN')

    expect(Message.where(id: lines.map(&:id)).count).to eq(3)
    expect(Dir.children(backup_dir)).to be_empty
  end

  it 'APPLY=1 CONFIRM=yes BACKUP_DIR writes the backup, deletes the lines only and leaves a repeated dry run at 0', :aggregate_failures do
    output = run_task('APPLY' => '1', 'CONFIRM' => 'yes', 'BACKUP_DIR' => backup_dir)

    expect(JSON.parse(output.lines.last)).to include('mode' => 'applied', 'messages' => 3, 'deleted' => 3, 'backup' => backup_file)
    expect(JSON.parse(File.read(backup_file))['messages'].pluck('id')).to eq(lines.map(&:id))
    expect(Message.where(id: lines.map(&:id))).to be_empty
    expect(Message.exists?(other_activity.id)).to be(true)
    expect(JSON.parse(run_task.lines.last)).to include('mode' => 'dry_run', 'messages' => 0, 'accounts' => 0)
  end

  it 'RESTORE=<file> is a dry run, with APPLY=1 CONFIRM=yes it puts the lines back with their ids', :aggregate_failures do
    run_task('APPLY' => '1', 'CONFIRM' => 'yes', 'BACKUP_DIR' => backup_dir)
    before_restore = lines.map { |line| [line.id, line.content, line.account_id, line.conversation_id, line.created_at.utc.iso8601(6)] }

    dry = run_task('RESTORE' => backup_file)
    expect(JSON.parse(dry.lines.last)).to include('mode' => 'restore_dry_run', 'to_restore' => 3, 'restored' => 0)
    expect(Message.where(id: lines.map(&:id))).to be_empty

    restored = run_task('RESTORE' => backup_file, 'APPLY' => '1', 'CONFIRM' => 'yes')
    expect(JSON.parse(restored.lines.last)).to include('mode' => 'restored', 'restored' => 3)
    expect(Message.where(id: lines.map(&:id)).order(:id).map do |message|
      [message.id, message.content, message.account_id, message.conversation_id, message.created_at.utc.iso8601(6)]
    end).to eq(before_restore)
    expect(JSON.parse(run_task.lines.last)).to include('messages' => 3)
  end

  describe 'refusals' do
    it 'APPLY=1 needs CONFIRM=yes', :aggregate_failures do
      [{}, { 'CONFIRM' => 'y' }, { 'CONFIRM' => 'YES' }].each do |confirm|
        expect { run_task({ 'APPLY' => '1', 'BACKUP_DIR' => backup_dir }.merge(confirm)) }
          .to raise_error(SystemExit).and output(/REFUSED: APPLY=1 needs CONFIRM=yes/).to_stderr
      end
      expect(Message.where(id: lines.map(&:id)).count).to eq(3)
    end

    it 'APPLY=1 needs BACKUP_DIR, and APPLY must be 1 or 0', :aggregate_failures do
      expect { run_task('APPLY' => '1', 'CONFIRM' => 'yes') }.to raise_error(SystemExit).and output(/REFUSED: BACKUP_DIR is required/).to_stderr
      expect { run_task('APPLY' => 'true') }.to raise_error(SystemExit).and output(/REFUSED: APPLY must be 1 or 0/).to_stderr
      expect(Message.where(id: lines.map(&:id)).count).to eq(3)
    end

    it 'RESTORE of a file that is not there is refused', :aggregate_failures do
      expect { run_task('RESTORE' => File.join(backup_dir, 'nothing.json'), 'APPLY' => '1', 'CONFIRM' => 'yes') }
        .to raise_error(SystemExit).and output(/REFUSED: .*cannot be read/).to_stderr
    end
  end
end
