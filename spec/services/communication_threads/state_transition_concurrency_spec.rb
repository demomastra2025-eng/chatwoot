require 'rails_helper'
require 'timeout'

# rubocop:disable RSpec/DescribeClass
RSpec.describe 'Communication thread state transition concurrency' do
  self.use_transactional_tests = false

  let!(:account) { create(:account) }
  let!(:thread) { create(:communication_thread, account: account, status: :open) }

  def wait_for_worker!(worker)
    result = Timeout.timeout(15) { worker.value }
    raise result if result.is_a?(StandardError)

    result
  end

  def wait_for_blocker!(blocked_pid:, blocker_pid:)
    blockers = Timeout.timeout(15) do
      loop do
        result = ActiveRecord::Base.connection.select_value("SELECT pg_blocking_pids(#{blocked_pid})")
        break result if result.present? && result != '{}'

        sleep 0.01
      end
    end
    expect(blockers).to include(blocker_pid.to_s)
  end

  after do
    thread.destroy! if CommunicationThread.exists?(thread.id)
    AutomationEvent.where(account_id: account.id).delete_all
    ConversationStatusTransition.where(account_id: account.id).delete_all
    account.destroy! if Account.exists?(account.id)
  end

  it 'serializes the same operation into one byte-equivalent fact' do
    event_id = SecureRandom.uuid
    occurred_at = Time.current.change(usec: 0)
    barrier = Concurrent::CyclicBarrier.new(2)

    results = Array.new(2) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          local_thread = CommunicationThread.find(thread.id)
          operation = CommunicationThreads::StateTransitionWriter.new(
            thread: local_thread,
            attributes: { status: 'resolved' },
            source: 'concurrent_spec',
            source_event_id: event_id,
            occurred_at: occurred_at
          )
          barrier.wait
          operation.perform
        rescue StandardError => e
          e
        end
      end
    end.map(&:value)

    expect(results).to all(be_a(CommunicationThreadStateTransitionFact))
    expect(results.map(&:id).uniq).to contain_exactly(results.first.id)
    expect(CommunicationThreadStateTransitionFact.where(account: account, source_event_id: event_id).count).to eq(1)
    expect(thread.reload).to be_resolved
  end

  it 'orders state facts by serialized transition even when a request started before the preceding writer' do
    thread
    earlier_request = Time.current.round(6) + 1.second
    later_request = earlier_request + 1.second
    delayed = CommunicationThreads::StateTransitionWriter.new(
      thread: thread, attributes: { status: 'pending' }, source_event_id: SecureRandom.uuid,
      occurred_at: earlier_request
    )
    preceding = CommunicationThreads::StateTransitionWriter.new(
      thread: CommunicationThread.find(thread.id), attributes: { status: 'resolved' },
      source_event_id: SecureRandom.uuid, occurred_at: later_request
    )

    preceding.perform
    recorded = delayed.perform
    facts = CommunicationThreadStateTransitionFact.where(communication_thread_id_snapshot: thread.id)
                                                  .order(:occurred_at, :id)

    expect(facts.pluck(:event_kind)).to eq(%w[created resolved reopened])
    expect(recorded.occurred_at).to be > later_request
    expect(recorded.requested_occurred_at).to eq(earlier_request)
    expect(delayed.perform).to eq(recorded)
  end

  it 'orders a direct SQL projection fallback after a future-dated locked writer fact' do
    thread
    requested = Time.current.round(6) + 2.seconds
    resolved = CommunicationThreads::StateTransitionWriter.new(
      thread: thread, attributes: { status: 'resolved' }, occurred_at: requested
    ).perform

    # rubocop:disable Rails/SkipsModelValidations
    thread.update_column(:status, CommunicationThread.statuses.fetch('open'))
    # rubocop:enable Rails/SkipsModelValidations
    fallback = CommunicationThreadStateTransitionFact.where(communication_thread_id_snapshot: thread.id).order(:id).last

    expect(fallback).to have_attributes(event_kind: 'reopened', source: 'database_projection_fallback')
    expect(fallback.requested_occurred_at).to be < resolved.occurred_at
    expect(fallback.occurred_at).to be > resolved.occurred_at
    expect(fallback.reliable_since).to eq(fallback.occurred_at)
  end

  it 'holds the Conversation lock before reopening a resolved Thread from an incoming message' do
    account.enable_features!('communication_threads')
    conversation = create(:conversation, account: account, contact: thread.contact)
    conversation.update!(status: :resolved)
    linked_thread = conversation.reload.communication_thread
    message = build(:message, account: account, conversation: conversation, sender: thread.contact, created_at: Time.current)
    entered = Queue.new
    release = Queue.new
    message.define_singleton_method(:perform_reopen_transition) do
      entered << true
      release.pop
      super()
    end
    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { message.send(:reopen_resolved_conversation) }
    rescue StandardError => e
      e
    end

    Timeout.timeout(15) { entered.pop }
    expect { Conversation.where(id: conversation.id).lock('FOR UPDATE NOWAIT').first }
      .to raise_error(ActiveRecord::LockWaitTimeout)
    expect(linked_thread.reload).to be_resolved
    competing = Queue.new
    racer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        competing << true
        Conversation.find(conversation.id).update!(status: :pending)
      end
    rescue StandardError => e
      e
    end
    Timeout.timeout(15) { competing.pop }
    release.push(true)
    result = Timeout.timeout(15) { worker.value }
    raced = Timeout.timeout(15) { racer.value }
    raise result if result.is_a?(StandardError)
    raise raced if raced.is_a?(StandardError)

    expect(linked_thread.reload).to be_pending
    expect(linked_thread.session_started_at).to be_within(0.001.seconds).of(message.created_at)
  ensure
    release&.push(true)
    result = Timeout.timeout(15) { worker.value } if worker&.alive?
    raced = Timeout.timeout(15) { racer.value } if racer&.alive?
    raise result if result.is_a?(StandardError)
    raise raced if raced.is_a?(StandardError)
  end

  it 'locks every channel before reopening either of two resolved conversations' do
    account.enable_features!('communication_threads')
    first = create(:conversation, account: account, contact: thread.contact, status: :resolved)
    second = create(:conversation, account: account, contact: thread.contact, status: :resolved)
    linked_thread = first.reload.communication_thread
    baseline_id = CommunicationThreadStateTransitionFact.maximum(:id)
    message = build(:message, account: account, conversation: first, sender: thread.contact, created_at: Time.current)
    other_message = build(:message, account: account, conversation: second, sender: thread.contact, created_at: Time.current)
    entered = Queue.new
    release = Queue.new
    message.define_singleton_method(:perform_reopen_transition) do
      entered << true
      release.pop
      super()
    end

    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { message.send(:reopen_resolved_conversation) }
    rescue StandardError => e
      e
    end
    Timeout.timeout(15) { entered.pop }
    expect { Conversation.where(id: second.id).lock('FOR UPDATE NOWAIT').first }
      .to raise_error(ActiveRecord::LockWaitTimeout)

    racer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { other_message.send(:reopen_resolved_conversation) }
    rescue StandardError => e
      e
    end
    release.push(true)
    [worker, racer].each do |running|
      result = Timeout.timeout(15) { running.value }
      raise result if result.is_a?(StandardError)
    end

    expect([first.reload.status, second.reload.status]).to eq(%w[open open])
    expect(CommunicationThreadStateTransitionFact.where('id > ?', baseline_id)
                                                  .where(communication_thread_id_snapshot: linked_thread.id).count).to eq(1)
  ensure
    release&.push(true)
    [worker, racer].compact.each do |running|
      result = Timeout.timeout(15) { running.value } if running.alive?
      raise result if result.is_a?(StandardError)
    end
  end

  %i[team_deletion aggregate_status].each do |operation|
    it "prelocks linked Conversations by id before a Thread update races with #{operation}" do # rubocop:disable RSpec/ExampleLength
      account.enable_features!('communication_threads')
      team = create(:team, account: account)
      first = create(:conversation, account: account, contact: thread.contact, team: team)
      second = create(:conversation, account: account, contact: thread.contact, team: team)
      linked_thread = first.reload.communication_thread
      first.communication_thread_conversation.destroy!
      first.refresh_communication_thread!
      expect(linked_thread.communication_thread_conversations.order(:id).pluck(:conversation_id))
        .to eq([second.id, first.id])
      entered = Queue.new
      release = Queue.new

      worker = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          service = CommunicationThreads::UpdateService.new(
            communication_thread: CommunicationThread.find(linked_thread.id),
            params: { status: 'resolved' }, accessible_links: linked_thread.communication_thread_conversations
          )
          service.define_singleton_method(:sync_conversation!) do |record|
            super(record)
            next unless record.id == second.id

            entered << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
            release.pop
          end
          service.perform
        end
      rescue StandardError => e
        e
      end
      worker_pid = Timeout.timeout(15) { entered.pop }
      expect { Conversation.where(id: first.id).lock('FOR UPDATE NOWAIT').first }
        .to raise_error(ActiveRecord::LockWaitTimeout)

      started = Queue.new
      competitor = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          started << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
          if operation == :team_deletion
            Team.find(team.id).destroy!
          else
            Conversations::StatusTransitionService.new(
              conversation: Conversation.find(first.id), params: { status: 'pending' }
            ).perform
          end
        end
      rescue StandardError => e
        e
      end
      competitor_pid = Timeout.timeout(15) { started.pop }
      blockers = Timeout.timeout(15) do
        loop do
          result = ActiveRecord::Base.connection.select_value("SELECT pg_blocking_pids(#{competitor_pid})")
          break result if result.present? && result != '{}'

          sleep 0.01
        end
      end
      expect(blockers).to include(worker_pid.to_s)
      release << true
      wait_for_worker!(worker)
      wait_for_worker!(competitor)

      expect([first.reload.status, second.reload.status]).to eq([operation == :aggregate_status ? 'pending' : 'resolved'] * 2)
      expect(linked_thread.reload.team_id).to be_nil if operation == :team_deletion
    ensure
      release&.push(true)
      [worker, competitor].compact.each { |running| wait_for_worker!(running) if running.alive? }
    end
  end

  it 'does not lock a Thread while Team deletion waits for a linked Conversation' do
    account.enable_features!('communication_threads')
    team = create(:team, account: account)
    conversation = create(:conversation, account: account, contact: thread.contact, team: team)
    linked_thread = conversation.reload.communication_thread
    held = Queue.new
    release = Queue.new
    deleting = Queue.new

    updater = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Conversation.transaction do
          record = Conversation.find(conversation.id)
          record.lock!
          held << true
          release.pop
          record.update!(status: :pending)
        end
      end
    rescue StandardError => e
      e
    end
    Timeout.timeout(15) { held.pop }

    destroyer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        record = Team.find(team.id)
        record.define_singleton_method(:record_communication_thread_nullifications) do
          deleting << self.class.connection.select_value('SELECT pg_backend_pid()').to_i
          super()
        end
        record.destroy!
      end
    rescue StandardError => e
      e
    end
    deleting_pid = Timeout.timeout(15) { deleting.pop }
    Timeout.timeout(15) do
      loop do
        blockers = ActiveRecord::Base.connection.select_value("SELECT pg_blocking_pids(#{deleting_pid})")
        break if blockers.present? && blockers != '{}'

        sleep 0.01
      end
    end
    expect { CommunicationThread.where(id: linked_thread.id).lock('FOR UPDATE NOWAIT').first }.not_to raise_error
    release.push(true)
    [updater, destroyer].each { |running| wait_for_worker!(running) }

    expect(conversation.reload.team_id).to be_nil
    expect(linked_thread.reload.team_id).to be_nil
  ensure
    release&.push(true)
    [updater, destroyer].compact.each { |running| wait_for_worker!(running) if running.alive? }
  end

  it 'serializes a late Team join before taking the Thread lock for deletion' do # rubocop:disable RSpec/ExampleLength
    account.enable_features!('communication_threads')
    team = create(:team, account: account)
    other_team = create(:team, account: account)
    joining = create(:conversation, account: account, contact: thread.contact, team: other_team)
    first = create(:conversation, account: account, contact: thread.contact, team: team)
    linked_thread = first.reload.communication_thread
    expect(linked_thread.team_id).to eq(team.id)
    entered = Queue.new
    release = Queue.new

    blocker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        CommunicationThread.transaction do
          CommunicationThread.find(linked_thread.id).lock!
          entered << true
          release.pop
        end
      end
    rescue StandardError => e
      e
    end
    Timeout.timeout(15) { entered.pop }
    destroying = Queue.new
    destroyer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        record = Team.find(team.id)
        record.define_singleton_method(:record_communication_thread_nullifications) do
          destroying << self.class.connection.select_value('SELECT pg_backend_pid()').to_i
          super()
        end
        record.destroy!
      end
    rescue StandardError => e
      e
    end
    deleting_pid = Timeout.timeout(15) { destroying.pop }
    Timeout.timeout(15) do
      loop do
        blockers = ActiveRecord::Base.connection.select_value("SELECT pg_blocking_pids(#{deleting_pid})")
        break if blockers.present? && blockers != '{}'

        sleep 0.01
      end
    end
    expect { Team.where(id: team.id).lock('FOR UPDATE NOWAIT').first }
      .to raise_error(ActiveRecord::LockWaitTimeout)

    joining_started = Queue.new
    joining_worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        joining_started << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
        Conversation.find(joining.id).update!(team: team)
      end
    rescue ActiveRecord::InvalidForeignKey, ActiveRecord::RecordNotFound
      :team_deleted
    rescue StandardError => e
      e
    end
    joining_pid = Timeout.timeout(15) { joining_started.pop }
    blockers = Timeout.timeout(15) do
      loop do
        result = ActiveRecord::Base.connection.select_value("SELECT pg_blocking_pids(#{joining_pid})")
        break result if result.present? && result != '{}'

        sleep 0.01
      end
    end
    expect(blockers).to include(deleting_pid.to_s)
    release << true
    wait_for_worker!(blocker)
    wait_for_worker!(destroyer)
    joining_result = Timeout.timeout(15) { joining_worker.value }
    raise joining_result if joining_result.is_a?(StandardError)

    expect(joining_result).to eq(:team_deleted)
    expect(first.reload.team_id).to be_nil
    expect(joining.reload.team_id).to eq(other_team.id)
    expect(linked_thread.reload.team_id).to be_nil
  ensure
    release&.push(true)
    [blocker, destroyer, joining_worker].compact.each { |running| wait_for_worker!(running) if running.alive? }
  end

  it 'protects a new routing Team before locking linked Conversations against deletion' do
    account.enable_features!('communication_threads')
    deleting_team = create(:team, account: account)
    other_team = create(:team, account: account)
    owner = create(:user, account: account)
    create(:team_member, team: deleting_team, user: owner)
    first = create(:conversation, account: account, contact: thread.contact, team: deleting_team)
    second = create(:conversation, account: account, contact: thread.contact, team: other_team)
    linked_thread = first.reload.communication_thread
    entered = Queue.new
    release = Queue.new

    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        service = CommunicationThreads::UpdateService.new(
          communication_thread: CommunicationThread.find(linked_thread.id),
          params: { assignee_id: owner.id }, accessible_links: linked_thread.communication_thread_conversations
        )
        service.define_singleton_method(:sync_conversation!) do |record|
          super(record)
          next unless record.id == first.id

          entered << true
          release.pop
        end
        service.perform
      end
    rescue StandardError => e
      e
    end
    Timeout.timeout(15) { entered.pop }
    expect { Team.where(id: deleting_team.id).lock('FOR UPDATE NOWAIT').first }
      .to raise_error(ActiveRecord::LockWaitTimeout)

    destroyer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { Team.find(deleting_team.id).destroy! }
    rescue StandardError => e
      e
    end
    release << true
    wait_for_worker!(worker)
    wait_for_worker!(destroyer)
    expect(second.reload.team_id).to be_nil
    expect(linked_thread.reload.team_id).to be_nil
  ensure
    release&.push(true)
    [worker, destroyer].compact.each { |running| wait_for_worker!(running) if running.alive? }
  end

  it 'locks all channels before a reminder resolves the higher-id channel' do
    account.enable_features!('communication_threads')
    first = create(:conversation, account: account, contact: thread.contact, status: :open)
    second = create(:conversation, account: account, contact: thread.contact, status: :open)
    linked_thread = first.reload.communication_thread
    entered = Queue.new
    release = Queue.new
    record = Conversation.find(second.id)
    record.define_singleton_method(:lock!) do |*args, **kwargs|
      super(*args, **kwargs).tap do
        entered << self.class.connection.select_value('SELECT pg_backend_pid()').to_i
        release.pop
      end
    end
    reminder_action = Reminders::PostDeliveryActionService.new(message: build(:message, conversation: record))

    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        reminder_action.send(:resolve_conversation!, record, { actor: nil, source: 'system' })
      end
    rescue StandardError => e
      e
    end
    worker_pid = Timeout.timeout(15) { entered.pop }
    expect { Conversation.where(id: first.id).lock('FOR UPDATE NOWAIT').first }
      .to raise_error(ActiveRecord::LockWaitTimeout)
    started = Queue.new
    competitor = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        started << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
        CommunicationThreads::UpdateService.new(
          communication_thread: CommunicationThread.find(linked_thread.id), params: { status: 'pending' },
          accessible_links: linked_thread.communication_thread_conversations
        ).perform
      end
    rescue StandardError => e
      e
    end
    competitor_pid = Timeout.timeout(15) { started.pop }
    wait_for_blocker!(blocked_pid: competitor_pid, blocker_pid: worker_pid)
    release << true
    [worker, competitor].each { |running| wait_for_worker!(running) }
    expect([first.reload.status, second.reload.status]).to eq(%w[pending pending])
  ensure
    release&.push(true)
    [worker, competitor].compact.each { |running| wait_for_worker!(running) if running.alive? }
  end

  it 'locks both Contacts before a merge can lock a Thread and race with owner fan-out' do
    account.enable_features!('communication_threads')
    base = thread.contact
    mergee = create(:contact, account: account)
    owner = create(:user, account: account)
    replacement = create(:user, account: account)
    base.update!(owner: owner)
    create(:conversation, account: account, contact: base, assignee: owner)
    create(:conversation, account: account, contact: mergee)
    baseline_id = CommunicationThreadStateTransitionFact.maximum(:id)
    entered = Queue.new
    release = Queue.new
    merge = ContactMergeAction.new(account: account, base_contact: Contact.find(base.id), mergee_contact: mergee)
    merge.define_singleton_method(:lock_contact_inboxes) do
      super()
      entered << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
      release.pop
    end
    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { merge.perform }
    rescue StandardError => e
      e
    end
    worker_pid = Timeout.timeout(15) { entered.pop }
    expect { Contact.where(id: base.id).lock('FOR UPDATE NOWAIT').first }
      .to raise_error(ActiveRecord::LockWaitTimeout)
    started = Queue.new
    competitor = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        started << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
        Contact.find(base.id).update!(owner: replacement)
      end
    rescue StandardError => e
      e
    end
    competitor_pid = Timeout.timeout(15) { started.pop }
    wait_for_blocker!(blocked_pid: competitor_pid, blocker_pid: worker_pid)
    release << true
    [worker, competitor].each { |running| wait_for_worker!(running) }
    expect(base.reload.owner_id).to eq(replacement.id)
    merged_thread = CommunicationThread.find_by!(account: account, contact: base)
    expect(merged_thread.assignee_id).to eq(replacement.id)
    expect(CommunicationThreadStateTransitionFact.where('id > ?', baseline_id)
                                                 .where(communication_thread_id_snapshot: merged_thread.id,
                                                        from_assignee_id: owner.id, to_assignee_id: replacement.id).count).to eq(1)
  ensure
    release&.push(true)
    [worker, competitor].compact.each { |running| wait_for_worker!(running) if running.alive? }
  end

  it 'locks Contact and target Team before a direct Conversation owner transfer' do
    account.enable_features!('communication_threads')
    team = create(:team, account: account)
    owner = create(:user, account: account)
    create(:team_member, team: team, user: owner)
    first = create(:conversation, account: account, contact: thread.contact)
    second = create(:conversation, account: account, contact: thread.contact)
    entered = Queue.new
    release = Queue.new

    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        record = Conversation.find(second.id)
        record.define_singleton_method(:lock_contact_conversations_before_assignee_change) do
          entered << true
          release.pop
          super()
        end
        record.update!(assignee: owner, team: team)
      end
    rescue StandardError => e
      e
    end
    Timeout.timeout(15) { entered.pop }
    expect { Contact.where(id: thread.contact_id).lock('FOR UPDATE NOWAIT').first }
      .to raise_error(ActiveRecord::LockWaitTimeout)
    expect { Team.where(id: team.id).lock('FOR UPDATE NOWAIT').first }
      .to raise_error(ActiveRecord::LockWaitTimeout)
    release << true
    wait_for_worker!(worker)
    expect([first.reload.assignee_id, second.reload.assignee_id]).to eq([owner.id, owner.id])
  ensure
    release&.push(true)
    wait_for_worker!(worker) if worker&.alive?
  end

  it 'locks the lower-id Conversation before changing the owner on a higher-id channel' do
    account.enable_features!('communication_threads')
    first = create(:conversation, account: account, contact: thread.contact)
    second = create(:conversation, account: account, contact: thread.contact)
    owner = create(:user, account: account)
    entered = Queue.new
    release = Queue.new

    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        record = Conversation.find(second.id)
        record.define_singleton_method(:sync_contact_owner_from_assignee) do
          entered << true
          release.pop
          super()
        end
        record.update!(assignee: owner)
      end
    rescue StandardError => e
      e
    end
    Timeout.timeout(15) { entered.pop }
    expect { Conversation.where(id: first.id).lock('FOR UPDATE NOWAIT').first }
      .to raise_error(ActiveRecord::LockWaitTimeout)
    release << true
    wait_for_worker!(worker)
    expect([first.reload.assignee_id, second.reload.assignee_id]).to eq([owner.id, owner.id])
  ensure
    release&.push(true)
    wait_for_worker!(worker) if worker&.alive?
  end

  it 'locks the Contact before changing a Conversation assignee' do
    conversation = build(:conversation, account: account, contact: thread.contact)
    conversation.skip_runtime_events = true
    conversation.save!
    owner = create(:user, account: account)
    updated = Queue.new
    release = Queue.new

    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        record = Conversation.find(conversation.id)
        record.skip_runtime_events = true
        record.define_singleton_method(:sync_contact_owner_from_assignee) do
          updated << true
          release.pop
          super()
        end
        record.update!(assignee: owner)
      rescue StandardError => e
        e
      end
    end

    Timeout.timeout(15) { updated.pop }
    expect { Contact.where(id: conversation.contact_id).lock('FOR UPDATE NOWAIT').first }
      .to raise_error(ActiveRecord::LockWaitTimeout)
  ensure
    release&.push(true)
    result = Timeout.timeout(15) { worker.value } if worker
    raise result if result.is_a?(StandardError)

    conversation&.destroy! if conversation&.persisted?
  end

  it 'locks the Contact before claiming a Conversation for auto-assignment' do
    conversation = build(:conversation, account: account, contact: thread.contact)
    conversation.skip_runtime_events = true
    conversation.save!
    agent = create(:user, account: account)
    entered = Queue.new
    release = Queue.new

    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        service = AutoAssignment::AssignmentService.new(inbox: conversation.inbox)
        service.define_singleton_method(:assignable_conversations_scope) do
          entered << true
          release.pop
          super()
        end
        Current.suppress_runtime_events = true
        service.send(:claim_and_assign, Conversation.find(conversation.id), agent)
      rescue StandardError => e
        e
      ensure
        Current.suppress_runtime_events = false
      end
    end

    Timeout.timeout(15) { entered.pop }
    expect { Contact.where(id: conversation.contact_id).lock('FOR UPDATE NOWAIT').first }
      .to raise_error(ActiveRecord::LockWaitTimeout)
  ensure
    release&.push(true)
    result = Timeout.timeout(15) { worker.value } if worker
    raise result if result.is_a?(StandardError)

    conversation&.destroy! if conversation&.persisted?
  end

  it 'protects the candidate Team before auto-assignment claims Conversation rows' do
    account.enable_features!('communication_threads')
    team = create(:team, account: account)
    agent = create(:user, account: account)
    create(:team_member, team: team, user: agent)
    conversation = create(:conversation, account: account, contact: thread.contact)
    entered = Queue.new
    release = Queue.new

    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        service = AutoAssignment::AssignmentService.new(inbox: conversation.inbox)
        service.define_singleton_method(:claim_contact_conversations) do |contact|
          entered << true
          release.pop
          super(contact)
        end
        Current.suppress_runtime_events = true
        service.send(:claim_and_assign, Conversation.find(conversation.id), agent)
      rescue StandardError => e
        e
      ensure
        Current.suppress_runtime_events = false
      end
    end

    Timeout.timeout(15) { entered.pop }
    expect { Team.where(id: team.id).lock('FOR UPDATE NOWAIT').first }
      .to raise_error(ActiveRecord::LockWaitTimeout)
    release << true
    expect(wait_for_worker!(worker)).to be(true)
    expect(conversation.reload).to have_attributes(assignee_id: agent.id, team_id: team.id)
  ensure
    release&.push(true)
    wait_for_worker!(worker) if worker&.alive?
  end

  it 'claims all contact channels in id order before auto-assigning the higher-id channel' do
    account.enable_features!('communication_threads')
    first = create(:conversation, account: account, contact: thread.contact)
    second = create(:conversation, account: account, contact: thread.contact)
    agent = create(:user, account: account)
    entered = Queue.new
    release = Queue.new

    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        service = AutoAssignment::AssignmentService.new(inbox: second.inbox)
        service.define_singleton_method(:assignable_conversations_scope) do
          entered << true
          release.pop
          super()
        end
        Current.suppress_runtime_events = true
        service.send(:claim_and_assign, Conversation.find(second.id), agent)
      rescue StandardError => e
        e
      ensure
        Current.suppress_runtime_events = false
      end
    end
    Timeout.timeout(15) { entered.pop }
    expect { Conversation.where(id: first.id).lock('FOR UPDATE NOWAIT').first }
      .to raise_error(ActiveRecord::LockWaitTimeout)
    release << true
    expect(wait_for_worker!(worker)).to be(true)
    expect([first.reload.assignee_id, second.reload.assignee_id]).to eq([agent.id, agent.id])
  ensure
    release&.push(true)
    wait_for_worker!(worker) if worker&.alive?
  end
end
# rubocop:enable RSpec/DescribeClass
