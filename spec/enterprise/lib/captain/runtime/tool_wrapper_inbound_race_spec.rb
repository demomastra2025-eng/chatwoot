require 'rails_helper'
require 'timeout'

RSpec.describe Captain::Runtime::ToolWrapper do
  self.use_transactional_tests = false

  let(:tool) do
    Class.new(Captain::Runtime::Tool) do
      def name
        'slow_read_only_captain_spec'
      end

      def description
        'Simulated slow external read-only request'
      end

      def metadata
        { read_only: true, risk_level: 'low' }
      end
    end.new
  end

  it 'does not hold the contact lock across a read-only tool lasting over the 14s ingress timeout' do
    account = create(:account)
    account.enable_features!('communication_threads')
    channel = create(:channel_widget, account: account)
    assistant = create(:captain_assistant, account: account)
    create(:captain_inbox, captain_assistant: assistant, inbox: channel.inbox)
    conversation = create(:conversation, account: account, inbox: channel.inbox, status: :pending)
    create(:message, message_type: :incoming, conversation: conversation)
    other_channel = create(:channel_widget, account: account)
    other_contact_inbox = create(:contact_inbox, contact: conversation.contact, inbox: other_channel.inbox)
    other_conversation = create(:conversation, account: account, contact: conversation.contact,
                                               inbox: other_channel.inbox, contact_inbox: other_contact_inbox)
    context = Captain::Runtime::RunContext.new({
                                                 state: {
                                                   account_id: account.id,
                                                   assistant_id: assistant.id,
                                                   conversation: { id: conversation.id }
                                                 }
                                               })
    started = Queue.new
    allow(tool).to receive(:perform) do
      started << true
      sleep(15)
      'read complete'
    end

    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { described_class.new(tool, context).call({}) }
    end
    Timeout.timeout(10) { started.pop }
    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.transaction do
          connection.execute("SET LOCAL statement_timeout = '14s'")
          create(:message, message_type: :incoming, conversation: Conversation.find(other_conversation.id))
        end
      end
    end

    Timeout.timeout(3) { writer.value }
    expect(worker).to be_alive
    expect(Message.where(conversation_id: other_conversation.id).incoming.count).to eq(1)
    expect(Timeout.timeout(20) { worker.value }).to eq('read complete')
  ensure
    [worker, writer].compact.each { |thread| thread.kill if thread.alive? }
    [worker, writer].compact.each(&:join)
    if account&.persisted?
      AutomationEvent.where(account_id: account.id).delete_all
      CommunicationThreadConversation.where(account_id: account.id).delete_all
      CommunicationThread.where(account_id: account.id).destroy_all
      account.destroy!
    end
  end

  it 'rejects a mutating action after an unlinked contact-channel message commits before its resolver' do
    account = create(:account)
    channel = create(:channel_widget, account: account)
    assistant = create(:captain_assistant, account: account)
    create(:captain_inbox, captain_assistant: assistant, inbox: channel.inbox)
    conversation = create(:conversation, account: account, inbox: channel.inbox, status: :pending)
    trigger = create(:message, message_type: :incoming, conversation: conversation)
    other_channel = create(:channel_widget, account: account)
    other_contact_inbox = create(:contact_inbox, contact: conversation.contact, inbox: other_channel.inbox)
    other_conversation = create(:conversation, account: account, contact: conversation.contact,
                                               inbox: other_channel.inbox, contact_inbox: other_contact_inbox)
    account.enable_features!('communication_threads')
    Conversations::CommunicationThreadResolver.new(conversation: conversation).perform
    expect(other_conversation.reload.communication_thread).to be_nil

    committed = Queue.new
    finish_callback = Queue.new
    allow_any_instance_of(Message).to receive(:execute_after_create_commit_callbacks).and_wrap_original do |callback|
      if callback.receiver.content == 'M2 before action'
        committed << callback.receiver.id
        finish_callback.pop
      end
      callback.call
    end
    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.transaction do
          connection.execute("SET LOCAL statement_timeout = '14s'")
          create(:message, message_type: :incoming, conversation: Conversation.find(other_conversation.id), content: 'M2 before action')
        end
      end
    end
    incoming_id = Timeout.timeout(10) { committed.pop }
    expect(Message.exists?(incoming_id)).to be(true)
    effects = []
    state = { account_id: account.id, conversation: { id: conversation.id },
              captain_response_fence: { control_generation: conversation.current_captain_control_generation,
                                        last_message_id: trigger.id } }

    expect do
      Captain::Conversation::ActionFenceService.new(assistant: assistant, state: state).with_effect! { effects << :mutated }
    end.to raise_error(Captain::Conversation::ControlGenerationStaleError)
    expect(effects).to be_empty
  ensure
    finish_callback << true if writer&.alive?
    writer&.join
    if account&.persisted?
      AutomationEvent.where(account_id: account.id).delete_all
      CommunicationThreadConversation.where(account_id: account.id).delete_all
      CommunicationThread.where(account_id: account.id).destroy_all
      account.destroy!
    end
  end

  it 'does not auto-resolve while a committed incoming waits for its cross-channel resolver' do
    account = create(:account)
    account.update!(auto_resolve_after: 60, captain_auto_resolve_mode: 'legacy')
    account.disable_features!('communication_threads')
    channel = create(:channel_widget, account: account)
    assistant = create(:captain_assistant, account: account)
    create(:captain_inbox, captain_assistant: assistant, inbox: channel.inbox)
    conversation = create(:conversation, account: account, inbox: channel.inbox, status: :pending)
    other_channel = create(:channel_widget, account: account)
    other_contact_inbox = create(:contact_inbox, contact: conversation.contact, inbox: other_channel.inbox)
    other_conversation = create(:conversation, account: account, contact: conversation.contact,
                                               inbox: other_channel.inbox, contact_inbox: other_contact_inbox)
    account.enable_features!('communication_threads')
    Conversations::CommunicationThreadResolver.new(conversation: conversation).perform
    expect(other_conversation.reload.communication_thread).to be_nil
    conversation.update_columns(last_activity_at: 2.hours.ago)

    committed = Queue.new
    finish_callback = Queue.new
    allow_any_instance_of(Message).to receive(:execute_after_create_commit_callbacks).and_wrap_original do |callback|
      if callback.receiver.content == 'M2 before auto-resolution'
        committed << callback.receiver.id
        finish_callback.pop
      end
      callback.call
    end
    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.transaction do
          connection.execute("SET LOCAL statement_timeout = '14s'")
          create(:message, message_type: :incoming, conversation: Conversation.find(other_conversation.id),
                           content: 'M2 before auto-resolution')
        end
      end
    end
    incoming_id = Timeout.timeout(10) { committed.pop }
    expect(Message.exists?(incoming_id)).to be(true)
    expect(other_conversation.reload.communication_thread).to be_nil

    Captain::InboxPendingConversationsResolutionJob.perform_now(channel.inbox)

    expect(conversation.reload).to be_pending
    expect(conversation.messages.outgoing).to be_empty
  ensure
    finish_callback << true if writer&.alive?
    writer&.join
    if account&.persisted?
      AutomationEvent.where(account_id: account.id).delete_all
      CommunicationThreadConversation.where(account_id: account.id).delete_all
      CommunicationThread.where(account_id: account.id).destroy_all
      account.destroy!
    end
  end
end
