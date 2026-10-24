# frozen_string_literal: true

require 'rails_helper'
require 'rake'
require 'tmpdir'

# The status tabs read only the status of the thread, which is the most urgent status of the person's conversations. The
# repair gives the threads written by the old rule (or left by a contact merge) that status, once, and writes nothing else.
RSpec.describe 'onelink:person_status_repair rake task' do # rubocop:disable RSpec/DescribeClass
  let(:task) { Rake::Task['onelink:person_status_repair'] }
  let(:backup_dir) { Dir.mktmpdir('person-status') }
  let(:account) { create(:account).tap { |record| record.enable_features!('communication_threads') } }
  let(:agent) { create(:user, account: account, role: :administrator) }

  # name => [statuses of the channels, status stored in the thread, status the person must have]
  let(:roster) do
    {
      'open and snoozed, stored snoozed' => [%w[open snoozed], 'snoozed', 'open'],
      'pending and snoozed, stored snoozed' => [%w[pending snoozed], 'snoozed', 'pending'],
      'open and resolved, stored resolved' => [%w[open resolved], 'resolved', 'open'],
      'snoozed and resolved, stored open' => [%w[snoozed resolved], 'open', 'snoozed'],
      'open and snoozed, stored open' => [%w[open snoozed], 'open', 'open'],
      'resolved twice, stored resolved' => [%w[resolved resolved], 'resolved', 'resolved']
    }
  end
  let!(:people) { roster.to_h { |name, (statuses, stored, _expected)| [name, person(statuses, stored)] } }

  # The state of the data written by the old rule: the conversations have their statuses, the thread has another one.
  def person(statuses, stored, account: self.account)
    contact = create(:contact, account: account)
    statuses.each do |status|
      inbox = create(:inbox, account: account)
      conversation = create(:conversation, account: account, contact: contact, inbox: inbox,
                                           contact_inbox: create(:contact_inbox, contact: contact, inbox: inbox), status: :resolved)
      conversation.update_columns(status: Conversation.statuses.fetch(status)) # rubocop:disable Rails/SkipsModelValidations
    end
    CommunicationThread.find_by!(account: account, contact: contact).tap do |thread|
      thread.update_columns(status: CommunicationThread.statuses.fetch(stored), updated_at: 2.days.ago) # rubocop:disable Rails/SkipsModelValidations
    end
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

  def summary(output)
    JSON.parse(output.lines.last)
  end

  def thread_statuses
    people.transform_values { |thread| thread.reload.status }
  end

  def expected_statuses
    roster.transform_values(&:last)
  end

  def tab_ids(status)
    CommunicationThreadFinder.new(agent, { status: status, assignee_type: 'all' }).perform[:communication_threads].map(&:id)
  end

  def database_state
    [Conversation.order(:id).pluck(:id, :status, :updated_at), Message.count, ConversationStatusTransition.count,
     CommunicationThread.order(:id).pluck(:id, :status, :updated_at)]
  end

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?('onelink:person_status_repair')
    Current.account = account
  end

  after do
    Current.reset
    FileUtils.remove_entry(backup_dir)
  end

  describe 'dry run' do
    it 'counts the threads that differ from the rule and says how they change', :aggregate_failures do
      output = run_task(account.id.to_s, 'true')

      expect(output).to include('DRY RUN: nothing was written.')
      expect(summary(output)).to include('dry_run' => true, 'threads' => 4, 'repaired' => 0)
      expect(summary(output)['by_change']).to eq(
        'snoozed -> open' => 1, 'snoozed -> pending' => 1, 'resolved -> open' => 1, 'open -> snoozed' => 1
      )
      thread = people.fetch('open and snoozed, stored snoozed')
      expect(output).to include("account=#{account.id} thread=#{thread.display_id} (id #{thread.id}) snoozed -> open")
    end

    it 'is a dry run when the second argument is left out, and writes nothing', :aggregate_failures do
      before_state = database_state

      output = run_task(account.id.to_s)

      expect(output).to include('DRY RUN: nothing was written.')
      expect(database_state).to eq(before_state)
      expect(Dir.children(backup_dir)).to be_empty
    end

    it 'covers every account with all and skips an account without communication threads', :aggregate_failures do
      other = create(:account).tap { |record| record.enable_features!('communication_threads') }
      person(%w[open resolved], 'resolved', account: other)
      other.disable_features!('communication_threads')

      output = run_task('all', 'true')

      expect(summary(output)).to include('threads' => 4, 'skipped_accounts' => [other.id])
    end
  end

  describe 'real run' do
    it 'gives every person the most urgent status of its channels', :aggregate_failures do
      expect(thread_statuses).not_to eq(expected_statuses)

      output = run_task(account.id.to_s, 'false')

      expect(thread_statuses).to eq(expected_statuses)
      expect(summary(output)).to include('dry_run' => false, 'threads' => 4, 'repaired' => 4, 'failed' => 0)
    end

    it 'writes the backup CSV with the status before and after first', :aggregate_failures do
      output = run_task(account.id.to_s, 'false')

      backup = Dir.glob(File.join(backup_dir, 'person_status_backup_*.csv')).sole
      rows = CSV.read(backup, headers: true)
      changes = {
        'open and snoozed, stored snoozed' => %w[snoozed open], 'pending and snoozed, stored snoozed' => %w[snoozed pending],
        'open and resolved, stored resolved' => %w[resolved open], 'snoozed and resolved, stored open' => %w[open snoozed]
      }
      expect(rows.headers).to eq(CommunicationThreads::PersonStatusRepair::BACKUP_HEADERS)
      expect(rows.to_h { |row| [row['thread_id'].to_i, [row['status_before'], row['status_after']]] })
        .to eq(changes.to_h { |name, change| [people.fetch(name).id, change] })
      expect(output).to include("Backup of the repaired threads: #{backup}")
    end

    it 'writes the status of the threads that differ and nothing else', :aggregate_failures do
      conversations_before = Conversation.order(:id).pluck(:id, :status, :updated_at)
      untouched = people.values_at('open and snoozed, stored open', 'resolved twice, stored resolved')
      untouched_before = untouched.map { |thread| thread.reload.updated_at }
      message_count = Message.count

      run_task(account.id.to_s, 'false')

      expect(Conversation.order(:id).pluck(:id, :status, :updated_at)).to eq(conversations_before)
      expect(Message.count).to eq(message_count)
      expect(untouched.map { |thread| thread.reload.updated_at }).to eq(untouched_before)
      expect(people.fetch('open and snoozed, stored snoozed').reload.updated_at).to be > 1.day.ago
    end

    it 'puts the repaired person into the tab of its status', :aggregate_failures do
      waiting = people.fetch('open and resolved, stored resolved')
      expect(tab_ids('open')).not_to include(waiting.id)

      run_task(account.id.to_s, 'false')

      expect(tab_ids('open')).to include(waiting.id)
      expect(tab_ids('resolved')).not_to include(waiting.id)
    end

    it 'finds nothing on a second run', :aggregate_failures do
      run_task(account.id.to_s, 'false')
      state = database_state

      output = run_task(account.id.to_s, 'false')

      expect(summary(output)).to include('threads' => 0, 'repaired' => 0)
      expect(database_state).to eq(state)
    end

    it 'does not write anything when the backup cannot be written', :aggregate_failures do
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
