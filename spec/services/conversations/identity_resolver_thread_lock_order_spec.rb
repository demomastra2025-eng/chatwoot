require 'rails_helper'
require 'timeout'

RSpec.describe Conversations::IdentityResolver do
  self.use_transactional_tests = false

  def cleanup_account(account)
    return unless account&.persisted?

    AutomationEvent.where(account_id: account.id).delete_all
    ConversationStatusTransition.where(account_id: account.id).delete_all
    CommunicationThreadConversation.where(account_id: account.id).delete_all
    CommunicationThread.where(account_id: account.id).destroy_all
    ContactChannelProfile.where(account_id: account.id).delete_all
    account.destroy!
  end

  it 'resolves a second channel before a concurrent thread owner route acquires its advisory lock' do
    account = create(:account)
    account.enable_features!('communication_threads')
    contact = create(:contact, account: account)
    first_inbox = create(:channel_widget, account: account).inbox
    first_conversation = create(:conversation, account: account, inbox: first_inbox, contact: contact)
    owner_thread = first_conversation.reload.communication_thread
    second_inbox = create(:channel_widget, account: account).inbox
    second_identity = create(:contact_inbox, contact: contact, inbox: second_inbox)
    agent = create(:user, account: account)
    held = Queue.new
    release = Queue.new
    route_pid = Queue.new
    resolver = described_class.new(contact_inbox: second_identity, identity_key: 'primary', attributes: { status: :open })
    allow(resolver).to receive(:create_conversation).and_wrap_original do |original, &block|
      held << true
      release.pop
      original.call(&block)
    end

    identity_writer = Thread.new { ActiveRecord::Base.connection_pool.with_connection { resolver.perform } }
    Timeout.timeout(8) { held.pop }
    route_writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        route_pid << connection.select_value('SELECT pg_backend_pid()')
        CommunicationThreads::UpdateService.new(
          communication_thread: CommunicationThread.find(owner_thread.id), params: { assignee_id: agent.id },
          accessible_links: owner_thread.communication_thread_conversations
        ).perform
      end
    end
    pid = Timeout.timeout(8) { route_pid.pop }
    Timeout.timeout(8) do
      sleep(0.01) until ActiveRecord::Base.connection.select_value(
        "SELECT wait_event FROM pg_stat_activity WHERE pid = #{Integer(pid)}"
      ) == 'advisory'
    end
    release << true
    second_conversation = Timeout.timeout(8) { identity_writer.value }
    Timeout.timeout(8) { route_writer.value }

    expect(second_conversation.reload).to have_attributes(contact_id: contact.id, contact_inbox_id: second_identity.id)
    expect(second_conversation.communication_thread.id).to eq(owner_thread.id)
    expect(contact.reload.owner_id).to eq(agent.id)
  ensure
    release << true if identity_writer&.alive?
    [identity_writer, route_writer].compact.each { |writer| writer.kill if writer.alive? }
    [identity_writer, route_writer].compact.each(&:join)
    cleanup_account(account)
  end

  it 'resolves a first SMS message for a new contact without an existing thread' do
    account = create(:account)
    account.enable_features!('communication_threads')
    channel = create(:channel_sms, account: account, phone_number: "+1555#{format('%07d', account.id)}")
    params = { from: '+14234234234', text: 'first SMS', id: 'sms-new-identity' }.with_indifferent_access

    Sms::IncomingMessageService.new(inbox: channel.inbox, params: params).perform

    contact_inbox = channel.inbox.contact_inboxes.find_by!(source_id: params[:from])
    conversation = contact_inbox.conversations.sole
    expect(conversation.reload).to have_attributes(contact_id: contact_inbox.contact_id, identity_key: 'primary')
    expect(conversation.communication_thread.contact_id).to eq(contact_inbox.contact_id)
    expect(conversation.messages.incoming.last.content).to eq('first SMS')
  ensure
    cleanup_account(account)
  end
end
