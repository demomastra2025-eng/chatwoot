# frozen_string_literal: true

require 'rails_helper'
require 'timeout'

RSpec.describe Conversations::CommunicationThreadResolver do
  self.use_transactional_tests = false

  def wait_for_contact_advisory(pid)
    Timeout.timeout(8) do
      loop do
        break if ActiveRecord::Base.connection.select_value(
          "SELECT wait_event FROM pg_stat_activity WHERE pid = #{Integer(pid)}"
        ) == 'advisory'

        sleep(0.01)
      end
    end
  end

  def cleanup_account(account)
    return unless account&.persisted?

    AutomationEvent.where(account_id: account.id).delete_all
    CommunicationThreadConversation.where(account_id: account.id).delete_all
    CommunicationThread.where(account_id: account.id).destroy_all
    account.destroy!
  end

  it 'lets an owner-lock holder acquire the conversation while a resolver waits for that owner' do
    account = create(:account)
    account.enable_features!('communication_threads')
    conversation = create(:conversation, account: account)
    owner_locked = Queue.new
    resolver_contact_locked = Queue.new
    proceed = Queue.new

    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        record = Conversation.find(conversation.id)
        record.with_captain_control_lock do
          owner_locked << true
          proceed.pop
          record.with_lock { record.reload }
        end
      end
    end
    Timeout.timeout(8) { owner_locked.pop }
    resolver = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        callback = lambda do |_name, _started, _finished, _id, payload|
          resolver_contact_locked << true if payload[:sql].to_s.include?('pg_advisory_xact_lock')
        end
        ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
          Conversations::CommunicationThreadResolver.new(conversation: Conversation.find(conversation.id)).perform
        end
      end
    end
    Timeout.timeout(8) { resolver_contact_locked.pop }
    proceed << true

    Timeout.timeout(8) { [holder, resolver].each(&:value) }
    expect(conversation.reload.communication_thread).to be_present
  ensure
    proceed << true if holder&.alive?
    [holder, resolver].compact.each { |thread| thread.kill if thread.alive? }
    [holder, resolver].compact.each(&:join)
    cleanup_account(account)
  end

  it 'waits for the resolver advisory lock before locking the owner on inline routing' do
    account = create(:account)
    account.enable_features!('communication_threads')
    channel = create(:channel_widget, account: account)
    assistant = create(:captain_assistant, account: account)
    create(:captain_inbox, captain_assistant: assistant, inbox: channel.inbox)
    conversation = create(:conversation, account: account, inbox: channel.inbox)
    owner = conversation.reload.communication_thread
    assignee = create(:user, account: account)
    advisory_held = Queue.new
    release_advisory = Queue.new
    waiter_pid = Queue.new

    resolver = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        CommunicationThread.transaction do
          described_class.lock_contact_thread!(account.id, conversation.contact_id)
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
          params: { assignee_id: assignee.id },
          accessible_links: owner.communication_thread_conversations
        ).perform
      end
    end
    pid = Timeout.timeout(8) { waiter_pid.pop }
    wait_for_contact_advisory(pid)
    # A thread-first writer would hold this row while waiting on the advisory
    # lock; the resolver would then deadlock trying to lock the same owner.
    expect(CommunicationThread.find(owner.id).with_lock { true }).to be(true)
    release_advisory << true
    Timeout.timeout(8) { [resolver, writer].each(&:value) }
    expect(owner.reload.assignee_id).to eq(assignee.id)
  ensure
    release_advisory << true if resolver&.alive?
    [resolver, writer].compact.each { |thread| thread.kill if thread.alive? }
    [resolver, writer].compact.each(&:join)
    cleanup_account(account)
  end

  it 'waits for the contact advisory lock before locking the owner in a Captain assignment tool' do
    account = create(:account)
    account.enable_features!('communication_threads')
    channel = create(:channel_widget, account: account)
    assistant = create(:captain_assistant, account: account)
    create(:captain_inbox, captain_assistant: assistant, inbox: channel.inbox)
    conversation = create(:conversation, account: account, inbox: channel.inbox, status: :pending)
    owner = conversation.reload.communication_thread
    agent = create(:user, account: account)
    advisory_held = Queue.new
    release_advisory = Queue.new
    waiter_pid = Queue.new

    resolver = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        CommunicationThread.transaction do
          described_class.lock_contact_thread!(account.id, conversation.contact_id)
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
        Captain::Conversation::ActionFenceService.new(
          assistant: assistant,
          state: {
            account_id: account.id, conversation: { id: conversation.id },
            captain_response_fence: { control_generation: conversation.current_captain_control_generation }
          }
        ).with_effect! do
          Conversations::AssignmentService.new(
            conversation: Conversation.find(conversation.id), assignee_id: agent.id, source: 'captain'
          ).perform
        end
      end
    end
    pid = Timeout.timeout(8) { waiter_pid.pop }
    wait_for_contact_advisory(pid)
    expect(CommunicationThread.find(owner.id).with_lock { true }).to be(true)
    release_advisory << true
    Timeout.timeout(8) { [resolver, writer].each(&:value) }
    expect(owner.reload.assignee_id).to eq(agent.id)
  ensure
    release_advisory << true if resolver&.alive?
    [resolver, writer].compact.each { |thread| thread.kill if thread.alive? }
    [resolver, writer].compact.each(&:join)
    cleanup_account(account)
  end
end
