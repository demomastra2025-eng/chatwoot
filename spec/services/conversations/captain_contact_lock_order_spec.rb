require 'rails_helper'
require 'timeout'

RSpec.describe Conversations::CommunicationThreadResolver do # rubocop:disable RSpec/SpecFilePathFormat
  self.use_transactional_tests = false

  def wait_for_advisory(pid)
    Timeout.timeout(8) do
      loop do
        break if ActiveRecord::Base.connection.select_value(
          "SELECT wait_event FROM pg_stat_activity WHERE pid = #{Integer(pid)}"
        ) == 'advisory'

        sleep(0.01)
      end
    end
  end

  def wait_for_row(pid)
    Timeout.timeout(8) do
      loop do
        event = ActiveRecord::Base.connection.select_value(
          "SELECT wait_event FROM pg_stat_activity WHERE pid = #{Integer(pid)}"
        )
        break if %w[transactionid tuple].include?(event)

        sleep(0.01)
      end
    end
  end

  def cleanup_account(account)
    return unless account&.persisted?

    AutomationEvent.where(account_id: account.id).delete_all
    ConversationStatusTransition.where(account_id: account.id).delete_all
    CommunicationThreadConversation.where(account_id: account.id).delete_all
    CommunicationThread.where(account_id: account.id).destroy_all
    account.destroy!
  end

  def pause_first_owner_projection!(held, release, projection_method: :sync_communication_threads!)
    mutex = Mutex.new
    pause_once = true
    allow(Contacts::OwnerSyncService).to receive(:new).and_wrap_original do |constructor, *args, **kwargs|
      service = constructor.call(*args, **kwargs)
      allow(service).to receive(projection_method).and_wrap_original do |projection|
        pause = mutex.synchronize do
          first = pause_once
          pause_once = false
          first
        end
        if pause
          held << true
          release.pop
        end
        projection.call
      end
      service
    end
  end

  it 'does not latch an unlinked Captain conversation before the Contact owner callback finishes' do
    account = create(:account)
    account.enable_features!('communication_threads')
    contact = create(:contact, account: account)
    inbox = create(:channel_widget, account: account).inbox
    assistant = create(:captain_assistant, account: account)
    create(:captain_inbox, captain_assistant: assistant, inbox: inbox)
    linked = create(:conversation, account: account, contact: contact, inbox: inbox, status: :pending)
    unlinked = create(:conversation, account: account, contact: contact, status: :pending)
    unlinked.communication_thread_conversation.destroy!
    unlinked.reload
    first_agent = create(:user, account: account)
    second_agent = create(:user, account: account)
    team = create(:team, account: account)
    create(:team_member, team: team, user: second_agent)
    contact_held = Queue.new
    release_contact = Queue.new
    writer_pid = Queue.new
    pause_first_owner_projection!(contact_held, release_contact, projection_method: :sync_conversations!)

    contact_writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Contact.transaction { Contact.find(contact.id).update!(owner: first_agent) }
      end
    end
    Timeout.timeout(8) { contact_held.pop }
    assignment = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        writer_pid << connection.select_value('SELECT pg_backend_pid()')
        Conversations::AssignmentService.new(
          conversation: Conversation.find(unlinked.id), assignee_id: second_agent.id, team_id: team.id
        ).perform
      end
    end
    wait_for_row(Timeout.timeout(8) { writer_pid.pop })
    expect(Conversation.where(id: unlinked.id).lock('FOR UPDATE NOWAIT').first).to be_present
    # OwnerSync now claims the linked Thread before Conversation projection.
    expect { CommunicationThread.where(id: linked.communication_thread.id).lock('FOR UPDATE NOWAIT').first }
      .to raise_error(ActiveRecord::LockWaitTimeout)
    release_contact << true
    Timeout.timeout(8) { [contact_writer, assignment].each(&:value) }
    expect(contact.reload.owner_id).to eq(second_agent.id)
    expect(unlinked.reload).to have_attributes(assignee_id: second_agent.id, team_id: team.id)
    expect(linked.reload).to have_attributes(assignee_id: second_agent.id, team_id: team.id)
    expect(linked.current_captain_control_state).to eq('human')
    expect(unlinked.current_captain_control_state).to eq('human')
  ensure
    release_contact << true if contact_writer&.alive?
    [contact_writer, assignment].compact.each { |worker| worker.kill if worker.alive? }
    [contact_writer, assignment].compact.each(&:join)
    cleanup_account(account)
  end

  it 'does not hold the Thread while a direct Contact owner callback owns the Contact row' do
    account = create(:account)
    account.enable_features!('communication_threads')
    contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: contact)
    thread_owner = conversation.reload.communication_thread
    first_agent = create(:user, account: account)
    second_agent = create(:user, account: account)
    contact_held = Queue.new
    release_contact = Queue.new
    writer_pid = Queue.new
    pause_first_owner_projection!(contact_held, release_contact)

    contact_writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Contact.transaction { Contact.find(contact.id).update!(owner: first_agent) }
      end
    end
    Timeout.timeout(8) { contact_held.pop }
    thread_writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        writer_pid << connection.select_value('SELECT pg_backend_pid()')
        CommunicationThreads::UpdateService.new(
          communication_thread: CommunicationThread.find(thread_owner.id),
          params: { assignee_id: second_agent.id },
          accessible_links: thread_owner.communication_thread_conversations
        ).perform
      end
    end

    wait_for_row(Timeout.timeout(8) { writer_pid.pop })
    # The competing route must wait on Contact, never claim Thread first.
    expect(CommunicationThread.where(id: thread_owner.id).lock('FOR UPDATE NOWAIT').first).to be_present
    release_contact << true
    Timeout.timeout(8) { [contact_writer, thread_writer].each(&:value) }
    expect(contact.reload.owner_id).to eq(second_agent.id)
    expect(thread_owner.reload.assignee_id).to eq(second_agent.id)
  ensure
    release_contact << true if contact_writer&.alive?
    [contact_writer, thread_writer].compact.each { |worker| worker.kill if worker.alive? }
    [contact_writer, thread_writer].compact.each(&:join)
    cleanup_account(account)
  end

  it 'locks Thread before channel rows when a direct Contact owner update races an aggregate status transition' do
    account = create(:account)
    account.enable_features!('communication_threads')
    contact = create(:contact, account: account)
    first = create(:conversation, account: account, contact: contact, status: :pending)
    second = create(:conversation, account: account, contact: contact, status: :pending)
    owner = first.reload.communication_thread
    agent = create(:user, account: account)
    projection_held = Queue.new
    release_projection = Queue.new
    status_pid = Queue.new
    pause_first_owner_projection!(projection_held, release_projection, projection_method: :sync_conversations!)

    owner_writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Contact.find(contact.id).update!(owner: agent)
      end
    end
    Timeout.timeout(8) { projection_held.pop }
    # Thread must already be owned by the Contact callback, before it saves a
    # Conversation; otherwise a Thread-first status/resolver can deadlock it.
    expect { CommunicationThread.where(id: owner.id).lock('FOR UPDATE NOWAIT').first }
      .to raise_error(ActiveRecord::LockWaitTimeout)
    expect(Conversation.where(id: first.id).lock('FOR UPDATE NOWAIT').first).to be_present

    status_writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        status_pid << connection.select_value('SELECT pg_backend_pid()')
        Conversations::StatusTransitionService.new(
          conversation: Conversation.find(first.id), params: { status: 'resolved' }, actor: agent, source: 'api'
        ).perform
      end
    end
    wait_for_row(Timeout.timeout(8) { status_pid.pop })
    release_projection << true
    Timeout.timeout(8) { [owner_writer, status_writer].each(&:value) }
    expect(first.reload).to have_attributes(status: 'resolved', assignee_id: agent.id)
    expect(second.reload).to have_attributes(status: 'resolved', assignee_id: agent.id)
    expect(owner.reload).to have_attributes(status: 'resolved', assignee_id: agent.id)
  ensure
    release_projection << true if owner_writer&.alive?
    [owner_writer, status_writer].compact.each { |worker| worker.kill if worker.alive? }
    [owner_writer, status_writer].compact.each(&:join)
    cleanup_account(account)
  end

  it 'keeps an unlinked status transition behind existing contact Threads before locking its Conversation' do
    account = create(:account)
    account.enable_features!('communication_threads')
    contact = create(:contact, account: account)
    linked = create(:conversation, account: account, contact: contact, status: :pending)
    unlinked = create(:conversation, account: account, contact: contact, status: :pending)
    unlinked.communication_thread_conversation.destroy!
    unlinked.reload
    agent = create(:user, account: account)
    held = Queue.new
    release = Queue.new
    status_pid = Queue.new
    pause_first_owner_projection!(held, release, projection_method: :sync_conversations!)

    owner_writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Contact.find(contact.id).update!(owner: agent)
      end
    end
    Timeout.timeout(8) { held.pop }
    status_writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        status_pid << connection.select_value('SELECT pg_backend_pid()')
        Conversations::StatusTransitionService.new(
          conversation: Conversation.find(unlinked.id), params: { status: 'resolved' }, actor: agent, source: 'api'
        ).perform
      end
    end
    wait_for_row(Timeout.timeout(8) { status_pid.pop })
    expect(Conversation.where(id: unlinked.id).lock('FOR UPDATE NOWAIT').first).to be_present
    release << true
    Timeout.timeout(8) { [owner_writer, status_writer].each(&:value) }
    expect(unlinked.reload.status).to eq('resolved')
    expect(linked.reload.assignee_id).to eq(agent.id)
  ensure
    release << true if owner_writer&.alive?
    [owner_writer, status_writer].compact.each { |worker| worker.kill if worker.alive? }
    [owner_writer, status_writer].compact.each(&:join)
    cleanup_account(account)
  end

  it 'locks existing Threads before an incoming message reopens an unlinked Conversation' do
    account = create(:account)
    account.enable_features!('communication_threads')
    contact = create(:contact, account: account)
    linked = create(:conversation, account: account, contact: contact, status: :pending)
    unlinked = create(:conversation, account: account, contact: contact, status: :resolved)
    unlinked.communication_thread_conversation.destroy!
    unlinked.reload
    agent = create(:user, account: account)
    held = Queue.new
    release = Queue.new
    message_pid = Queue.new
    pause_first_owner_projection!(held, release, projection_method: :sync_conversations!)

    owner_writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { Contact.find(contact.id).update!(owner: agent) }
    end
    Timeout.timeout(8) { held.pop }
    message_writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        message_pid << connection.select_value('SELECT pg_backend_pid()')
        Message.create!(account: account, conversation: Conversation.find(unlinked.id), inbox: unlinked.inbox,
                        sender: Contact.find(contact.id), message_type: :incoming, content: 'Reopen after delivery')
      end
    end
    wait_for_row(Timeout.timeout(8) { message_pid.pop })
    # after_commit must wait on the existing Thread, not hold the unlinked C
    # and then wait for the Contact owner callback to project into it.
    expect(Conversation.where(id: unlinked.id).lock('FOR UPDATE NOWAIT').first).to be_present
    release << true
    Timeout.timeout(8) { [owner_writer, message_writer].each(&:value) }
    expect(unlinked.reload).to have_attributes(status: 'open', assignee_id: agent.id)
    expect(linked.reload.assignee_id).to eq(agent.id)
  ensure
    release << true if owner_writer&.alive?
    [owner_writer, message_writer].compact.each { |worker| worker.kill if worker.alive? }
    [owner_writer, message_writer].compact.each(&:join)
    cleanup_account(account)
  end

  it 'locks the existing Thread before a direct Conversation status update enters the resolver' do
    account = create(:account)
    account.enable_features!('communication_threads')
    contact = create(:contact, account: account)
    linked = create(:conversation, account: account, contact: contact, status: :pending)
    unlinked = create(:conversation, account: account, contact: contact, status: :pending)
    unlinked.communication_thread_conversation.destroy!
    unlinked.reload
    agent = create(:user, account: account)
    held = Queue.new
    release = Queue.new
    status_pid = Queue.new
    pause_first_owner_projection!(held, release, projection_method: :sync_conversations!)

    owner_writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { Contact.find(contact.id).update!(owner: agent) }
    end
    Timeout.timeout(8) { held.pop }
    status_writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        status_pid << connection.select_value('SELECT pg_backend_pid()')
        Conversation.find(unlinked.id).update!(status: :resolved)
      end
    end
    wait_for_row(Timeout.timeout(8) { status_pid.pop })
    expect(Conversation.where(id: unlinked.id).lock('FOR UPDATE NOWAIT').first).to be_present
    release << true
    Timeout.timeout(8) { [owner_writer, status_writer].each(&:value) }
    expect(unlinked.reload.status).to eq('resolved')
    expect(linked.reload.assignee_id).to eq(agent.id)
  ensure
    release << true if owner_writer&.alive?
    [owner_writer, status_writer].compact.each { |worker| worker.kill if worker.alive? }
    [owner_writer, status_writer].compact.each(&:join)
    cleanup_account(account)
  end

  it 'keeps an unlinked Captain handoff behind existing Threads before locking the Conversation' do
    account = create(:account)
    account.enable_features!('communication_threads')
    contact = create(:contact, account: account)
    linked = create(:conversation, account: account, contact: contact, status: :pending)
    unlinked = create(:conversation, account: account, contact: contact, status: :pending)
    unlinked.communication_thread_conversation.destroy!
    unlinked.reload
    agent = create(:user, account: account)
    held = Queue.new
    release = Queue.new
    handoff_pid = Queue.new
    pause_first_owner_projection!(held, release, projection_method: :sync_conversations!)

    owner_writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { Contact.find(contact.id).update!(owner: agent) }
    end
    Timeout.timeout(8) { held.pop }
    handoff_writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        handoff_pid << connection.select_value('SELECT pg_backend_pid()')
        Captain::Conversation::ControlService.new(Conversation.find(unlinked.id))
                                             .handoff!(status_reason: nil, actor: agent, source: 'api')
      end
    end
    wait_for_row(Timeout.timeout(8) { handoff_pid.pop })
    expect(Conversation.where(id: unlinked.id).lock('FOR UPDATE NOWAIT').first).to be_present
    release << true
    Timeout.timeout(8) { [owner_writer, handoff_writer].each(&:value) }
    expect(unlinked.reload.current_captain_control_state).to eq('human')
    expect(linked.reload.assignee_id).to eq(agent.id)
  ensure
    release << true if owner_writer&.alive?
    [owner_writer, handoff_writer].compact.each { |worker| worker.kill if worker.alive? }
    [owner_writer, handoff_writer].compact.each(&:join)
    cleanup_account(account)
  end

  it 'takes advisory before auto-assignment claims Contact and enters the resolver callback' do
    account = create(:account)
    account.enable_features!('communication_threads')
    contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: contact, status: :open)
    thread_owner = conversation.reload.communication_thread
    auto_agent = create(:user, account: account)
    route_agent = create(:user, account: account)
    entered = Queue.new
    release_assignment = Queue.new
    writer_pid = Queue.new

    assignment = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        service = AutoAssignment::AssignmentService.new(inbox: conversation.inbox)
        service.define_singleton_method(:claim_contact_conversations) do |locked_contact|
          entered << true
          release_assignment.pop
          super(locked_contact)
        end
        Current.suppress_runtime_events = true
        service.send(:claim_and_assign, Conversation.find(conversation.id), auto_agent)
      ensure
        Current.suppress_runtime_events = false
      end
    end
    Timeout.timeout(8) { entered.pop }
    route = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        writer_pid << connection.select_value('SELECT pg_backend_pid()')
        CommunicationThreads::UpdateService.new(
          communication_thread: CommunicationThread.find(thread_owner.id),
          params: { assignee_id: route_agent.id },
          accessible_links: thread_owner.communication_thread_conversations
        ).perform
      end
    end
    wait_for_advisory(Timeout.timeout(8) { writer_pid.pop })
    expect(CommunicationThread.where(id: thread_owner.id).lock('FOR UPDATE NOWAIT').first).to be_present
    release_assignment << true
    Timeout.timeout(8) { [assignment, route].each(&:value) }
    expect(conversation.reload.assignee_id).to eq(route_agent.id)
    expect(contact.reload.owner_id).to eq(route_agent.id)
  ensure
    release_assignment << true if assignment&.alive?
    [assignment, route].compact.each { |worker| worker.kill if worker.alive? }
    [assignment, route].compact.each(&:join)
    cleanup_account(account)
  end

  it 'waits for contact advisory before acquiring the owner during routing' do
    account = create(:account)
    account.enable_features!('communication_threads')
    contact = create(:contact, account: account)
    channel = create(:channel_widget, account: account)
    assistant = create(:captain_assistant, account: account)
    create(:captain_inbox, captain_assistant: assistant, inbox: channel.inbox)
    conversation = create(:conversation, account: account, contact: contact, inbox: channel.inbox)
    owner = conversation.reload.communication_thread
    agent = create(:user, account: account)
    advisory_held = Queue.new
    release_advisory = Queue.new
    waiter_pid = Queue.new

    resolver = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        CommunicationThread.transaction do
          described_class.lock_contact_thread!(account.id, contact.id)
          advisory_held << true
          release_advisory.pop
          described_class.new(conversation: Conversation.find(conversation.id)).perform
        end
      end
    end
    Timeout.timeout(8) { advisory_held.pop }
    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        waiter_pid << connection.select_value('SELECT pg_backend_pid()')
        CommunicationThreads::UpdateService.new(
          communication_thread: CommunicationThread.find(owner.id),
          params: { assignee_id: agent.id },
          accessible_links: owner.communication_thread_conversations
        ).perform
      end
    end
    pid = Timeout.timeout(8) { waiter_pid.pop }
    wait_for_advisory(pid)
    # A writer which locked the owner first would block this probe.
    expect(CommunicationThread.find(owner.id).with_lock { true }).to be(true)
    release_advisory << true
    Timeout.timeout(8) { [resolver, writer].each(&:value) }
    expect(owner.reload.assignee_id).to eq(agent.id)
    expect(owner.captain_control_state).to eq('human')
  ensure
    release_advisory << true if resolver&.alive?
    [resolver, writer].compact.each { |thread| thread.kill if thread.alive? }
    [resolver, writer].compact.each(&:join)
    cleanup_account(account)
  end
end
