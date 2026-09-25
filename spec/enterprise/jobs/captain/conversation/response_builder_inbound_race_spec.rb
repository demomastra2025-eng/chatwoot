require 'rails_helper'

RSpec.describe Captain::Conversation::ResponseBuilderJob, type: :job do
  self.use_transactional_tests = false

  def cleanup_account(account)
    return unless account&.persisted?

    AutomationEvent.where(account_id: account.id).delete_all
    CommunicationThreadConversation.where(account_id: account.id).delete_all
    CommunicationThread.where(account_id: account.id).destroy_all
    account.destroy!
  end

  it 'waits for an unlinked cross-channel inbound commit before persisting a public reply' do
    account = create(:account)
    primary_channel = create(:channel_widget, account: account)
    assistant = create(:captain_assistant, account: account)
    create(:captain_inbox, captain_assistant: assistant, inbox: primary_channel.inbox)
    conversation = create(:conversation, account: account, inbox: primary_channel.inbox, status: :pending)
    trigger = create(:message, message_type: :incoming, conversation: conversation)
    other_channel = create(:channel_widget, account: account)
    contact_inbox = create(:contact_inbox, contact: conversation.contact, inbox: other_channel.inbox)
    other_conversation = create(:conversation, account: account, contact: conversation.contact,
                                               inbox: other_channel.inbox, contact_inbox: contact_inbox)

    persistence_locks = Queue.new
    allow(Conversations::CommunicationThreadResolver).to receive(:lock_contact_thread!).and_wrap_original do |original, *args|
      persistence_locks << args if Thread.current[:captain_response_persist]
      original.call(*args)
    end

    inbound_uncommitted = Queue.new
    commit_inbound = Queue.new
    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Message.transaction do
          create(:message, message_type: :incoming, conversation: Conversation.find(other_conversation.id))
          inbound_uncommitted << true
          commit_inbound.pop
        end
      end
    end
    Timeout.timeout(10) { inbound_uncommitted.pop }
    job = described_class.new
    job.send(:initialize_response_context, Conversation.find(conversation.id), assistant, nil, trigger.id,
             conversation.current_captain_control_generation)
    job.instance_variable_set(:@response, { 'response' => 'Stale AI response', 'usage' => {} })
    responder = Thread.new do
      Thread.current[:captain_response_persist] = true
      ActiveRecord::Base.connection_pool.with_connection do
        begin
          job.send(:process_pending_response)
        rescue Captain::Conversation::ControlGenerationStaleError
          :stale
        end
      end
    end
    expect(responder.join(0.5)).to be_nil # Until the inbound commits the contact lock cannot be claimed.
    commit_inbound << true
    Timeout.timeout(10) { writer.value }
    expect(Timeout.timeout(10) { responder.value }).to eq(:stale)
    expect(Timeout.timeout(1) { persistence_locks.pop }).to eq([account.id, conversation.contact_id])
    expect(conversation.messages.outgoing.where(sender: assistant, content: 'Stale AI response')).not_to exist
  ensure
    commit_inbound << true if writer&.alive?
    [responder, writer].compact.each { |thread| thread.kill if thread.alive? }
    [responder, writer].compact.each(&:join)
    cleanup_account(account)
  end
end
