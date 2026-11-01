# frozen_string_literal: true

require 'rails_helper'
require 'rake'
require 'tmpdir'

RSpec.describe 'onelink:one_open_dialog_per_thread rake task' do # rubocop:disable RSpec/DescribeClass
  include ActiveJob::TestHelper

  let(:task) { Rake::Task['onelink:one_open_dialog_per_thread'] }
  let(:backup_dir) { Dir.mktmpdir('one-open-dialog') }
  let(:account) do
    create(:account, limits: { non_web_inboxes: ChatwootApp.max_limit }).tap { |record| record.enable_features!('communication_threads') }
  end
  let(:contact) { create(:contact, account: account, phone_number: '+77011234567') }
  let(:voice_inbox) { create(:channel_voice, :sipuni, account: account).inbox }
  let(:old_inbox) { create(:channel_whatsapp_web, account: account).inbox }
  let(:current_inbox) { create(:channel_whatsapp_web, account: account).inbox }
  let(:call_ref) { 'call-1' }
  let!(:voice) { open_dialog(voice_inbox, minutes_ago: 1) }
  let!(:old_chat) { open_dialog(old_inbox, minutes_ago: 3000) }
  let!(:current_chat) { open_dialog(current_inbox, minutes_ago: 10) }
  let!(:second_contact_chats) do
    other_contact = create(:contact, account: account, phone_number: '+77017654321')
    [open_dialog(old_inbox, minutes_ago: 50, contact: other_contact), open_dialog(current_inbox, minutes_ago: 10, contact: other_contact)]
  end

  # The state of the production data: several open conversations of one person, put there without the live rule. The
  # conversations are created resolved (the live rule only looks at open ones) and opened together afterwards.
  def open_dialog(inbox, minutes_ago:, contact: self.contact)
    create(:conversation, account: inbox.account, contact: contact, inbox: inbox, status: :resolved).tap do |conversation|
      conversation.update_columns(last_activity_at: minutes_ago.minutes.ago) # rubocop:disable Rails/SkipsModelValidations
      dialogs_to_open << conversation.id
    end
  end

  def dialogs_to_open
    @dialogs_to_open ||= []
  end

  def open_pending_dialogs!
    Conversation.where(id: dialogs_to_open).update_all(status: Conversation.statuses.fetch('open')) # rubocop:disable Rails/SkipsModelValidations
    dialogs_to_open.clear
  end

  def run_task(*, backup: backup_dir)
    task.reenable
    output = StringIO.new
    $stdout = output
    with_modified_env('BACKUP_DIR' => backup) { task.invoke(*) }
    output.string
  ensure
    $stdout = STDOUT
  end

  def database_state
    [Conversation.order(:id).pluck(:id, :status, :additional_attributes, :custom_attributes, :updated_at),
     Message.count, ConversationStatusTransition.count, CommunicationThread.order(:id).pluck(:id, :status, :updated_at)]
  end

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?('onelink:one_open_dialog_per_thread')
    open_pending_dialogs!
  end

  after { FileUtils.remove_entry(backup_dir) }

  describe 'dry run' do
    it 'prints the counts and the (thread, kept, closed) list', :aggregate_failures do
      output = run_task(account.id.to_s, 'true')

      thread = CommunicationThread.find_by!(account: account, contact: contact)
      expect(output).to include("account=#{account.id} thread=#{thread.display_id} (id #{thread.id})")
      expect(output).to include("kept=#{current_chat.display_id} (id #{current_chat.id}")
      expect(output).to match(/closed=\[.*#{voice.display_id} \(id #{voice.id}.*#{old_chat.display_id} \(id #{old_chat.id}/)
      expect(output).to include('DRY RUN: nothing was written.')
      summary = JSON.parse(output.lines.last)
      expect(summary).to include('dry_run' => true, 'threads' => 2, 'conversations_to_resolve' => 3)
      expect(summary['by_channels']).to eq(
        'Channel::Voice + Channel::WhatsappWeb + Channel::WhatsappWeb' => 1, 'Channel::WhatsappWeb + Channel::WhatsappWeb' => 1
      )
    end

    it 'is a dry run when the second argument is left out, and writes nothing', :aggregate_failures do
      before_state = database_state
      clear_enqueued_jobs

      output = run_task(account.id.to_s)

      expect(output).to include('DRY RUN: nothing was written.')
      expect(database_state).to eq(before_state)
      expect(Dir.children(backup_dir)).to be_empty
      expect(enqueued_jobs).to be_empty
    end

    it 'reports a deferred thread instead of touching a live call', :aggregate_failures do
      voice.update_columns(additional_attributes: { 'call_status' => 'ringing' }) # rubocop:disable Rails/SkipsModelValidations

      output = run_task(account.id.to_s, 'true')

      expect(JSON.parse(output.lines.last)).to include('threads' => 1, 'deferred_live_call' => 1)
    end

    it 'covers every account with all, and skips an account without communication threads', :aggregate_failures do
      other = create(:account).tap { |record| record.enable_features!('communication_threads') }
      inbox_one = create(:inbox, account: other)
      inbox_two = create(:inbox, account: other)
      other_contact = create(:contact, account: other)
      open_dialog(inbox_one, minutes_ago: 9, contact: other_contact)
      open_dialog(inbox_two, minutes_ago: 1, contact: other_contact)
      open_pending_dialogs!
      other.disable_features!('communication_threads')

      output = run_task('all', 'true')

      expect(JSON.parse(output.lines.last)).to include('threads' => 2, 'skipped_accounts' => [other.id])
    end
  end

  describe 'real run' do
    it 'writes the backup CSV of the affected conversations first, then resolves them', :aggregate_failures do
      before_rows = Conversation.where(id: [voice.id, old_chat.id, current_chat.id]).order(:id).pluck(:id, :status)

      output = run_task(account.id.to_s, 'false')

      backup = Dir.glob(File.join(backup_dir, 'one_open_dialog_backup_*.csv')).sole
      rows = CSV.read(backup, headers: true)
      expect(rows.headers).to eq(CommunicationThreads::SingleOpenDialogCleanup::BACKUP_HEADERS)
      expect(rows.map { |row| [row['conversation_id'].to_i, row['status']] }).to include(*before_rows.map { |id, status| [id, status] })
      expect(rows.map { |row| row['planned_action'] }.tally).to eq('keep' => 2, 'resolve' => 3)
      expect(output).to include("Backup of the affected conversations: #{backup}")
      expect(JSON.parse(output.lines.last)).to include('dry_run' => false, 'resolved' => 3, 'failed' => 0)
      expect(Conversation.where(account_id: account.id, status: 'open').pluck(:id)).to contain_exactly(current_chat.id, second_contact_chats.last.id)
    end

    it 'resolves silently and leaves nothing to do on a second run', :aggregate_failures do
      dispatcher = Rails.configuration.dispatcher
      allow(dispatcher).to receive(:dispatch).and_call_original

      run_task(account.id.to_s, 'false')
      perform_enqueued_jobs(only: Conversations::ActivityMessageJob)

      expect(Message.where(account_id: account.id, content_type: :input_csat)).to be_empty
      expect(dispatcher).not_to have_received(:dispatch).with(Events::Types::CONVERSATION_RESOLVED, anything, anything)
      expect(Message.where(account_id: account.id, message_type: %w[outgoing template])).to be_empty
      expect(current_chat.messages.activity).to be_empty # the merge writes no line into the dialog that stays
      expect(JSON.parse(run_task(account.id.to_s, 'true').lines.last)).to include('threads' => 0)
    end

    it 'keeps the waiting-for-callback state of a missed call on the dialog that stays', :aggregate_failures do
      voice.update_columns( # rubocop:disable Rails/SkipsModelValidations
        custom_attributes: { 'waiting_for_callback' => true },
        additional_attributes: { 'waiting_for_callback' => true, 'last_missed_call_ref' => call_ref }
      )

      run_task(account.id.to_s, 'false')

      expect(current_chat.reload.additional_attributes).to include('waiting_for_callback' => true, 'last_missed_call_ref' => call_ref)
      expect(current_chat.custom_attributes).to include('waiting_for_callback' => true)
      expect(voice.reload).to be_resolved
    end

    # The old person update snoozed every channel of a person, the ones resolved long ago too: their timers would open all of
    # them together. One stays snoozed (the one a person is reached in, with its own timer); next to an open dialog none stays.
    it 'leaves one conversation of a person whose channels were snoozed together, silently', :aggregate_failures do
      until_time = 2.days.from_now
      snoozed_person = create(:contact, account: account, phone_number: '+77015550001')
      sleeping = [[old_inbox, 90_000], [current_inbox, 20], [voice_inbox, 60_000]].map do |inbox, minutes_ago|
        open_dialog(inbox, minutes_ago: minutes_ago, contact: snoozed_person)
      end
      open_person = create(:contact, account: account, phone_number: '+77015550002')
      open_chat = open_dialog(current_inbox, minutes_ago: 30, contact: open_person)
      open_pending_dialogs!
      leftover = open_dialog(old_inbox, minutes_ago: 10, contact: open_person)
      snoozed_ids = sleeping.map(&:id) + [leftover.id]
      Conversation.where(id: snoozed_ids).update_all(status: Conversation.statuses.fetch('snoozed'), snoozed_until: until_time) # rubocop:disable Rails/SkipsModelValidations
      dispatcher = Rails.configuration.dispatcher
      allow(dispatcher).to receive(:dispatch).and_call_original

      dry_run = JSON.parse(run_task(account.id.to_s, 'true').lines.last)
      expect(dry_run).to include('threads' => 4, 'conversations_to_resolve' => 6)

      run_task(account.id.to_s, 'false')

      expect(sleeping.map { |conversation| conversation.reload.status }).to eq(%w[resolved snoozed resolved])
      expect(sleeping.second.snoozed_until).to be_within(1.minute).of(until_time)
      expect([open_chat, leftover].map { |conversation| conversation.reload.status }).to eq(%w[open resolved])
      expect(dispatcher).not_to have_received(:dispatch).with(Events::Types::CONVERSATION_STATUS_CHANGED, anything, anything)
      expect(CommunicationThread.find_by!(account: account, contact: snoozed_person).status).to eq('snoozed')
      expect(JSON.parse(run_task(account.id.to_s, 'true').lines.last)).to include('threads' => 0)
    end

    it 'does not resolve anything when the backup cannot be written', :aggregate_failures do
      file_in_the_way = File.join(backup_dir, 'not-a-directory')
      File.write(file_in_the_way, 'x')
      before_state = database_state

      expect { run_task(account.id.to_s, 'false', backup: file_in_the_way) }.to raise_error(SystemCallError)

      expect(database_state).to eq(before_state)
    end
  end

  describe 'arguments' do
    it 'requires an account or all' do
      expect { run_task }.to raise_error(SystemExit)
    end

    it 'rejects an unknown account and an unclear dry_run', :aggregate_failures do
      expect { run_task('0', 'true') }.to raise_error(SystemExit)
      expect { run_task(account.id.to_s, 'maybe') }.to raise_error(SystemExit)
    end
  end
end
