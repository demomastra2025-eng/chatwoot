require 'rails_helper'
require 'timeout'

RSpec.describe 'widget contact update and thread routing lock order', type: :request do
  self.use_transactional_tests = false

  def wait_for_advisory(pid)
    Timeout.timeout(8) do
      sleep(0.01) until ActiveRecord::Base.connection.select_value(
        "SELECT wait_event FROM pg_stat_activity WHERE pid = #{Integer(pid)}"
      ) == 'advisory'
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

  def pause_contact_update(held, release)
    allow(ContactIdentifyAction).to receive(:new).and_wrap_original do |constructor, *args, **kwargs|
      constructor.call(*args, **kwargs).tap do |action|
        allow(action).to receive(:update_contact).and_wrap_original do |original|
          original.call
          held << true
          release.pop
        end
      end
    end
  end

  it 'takes the thread advisory before updating a contact and creating its second channel conversation' do
    account = create(:account)
    account.enable_features!('communication_threads')
    contact = create(:contact, account: account, email: nil, phone_number: nil)
    first_inbox = create(:channel_widget, account: account).inbox
    first_conversation = create(:conversation, account: account, inbox: first_inbox, contact: contact)
    owner_thread = first_conversation.reload.communication_thread
    widget = create(:channel_widget, account: account)
    widget_identity = create(:contact_inbox, contact: contact, inbox: widget.inbox)
    token = Widget::TokenService.new(payload: { source_id: widget_identity.source_id, inbox_id: widget.inbox.id }).generate_token
    agent = create(:user, account: account)
    held = Queue.new
    release = Queue.new
    route_pid = Queue.new
    pause_contact_update(held, release)

    widget_writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        post '/api/v1/widget/conversations',
             headers: { 'X-Auth-Token' => token },
             params: { website_token: widget.website_token, contact: { name: 'updated by widget' },
                       message: { content: 'second channel' } }, as: :json
        response.status
      end
    end
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
    wait_for_advisory(pid)
    release << true
    expect(Timeout.timeout(8) { widget_writer.value }).to eq(200)
    Timeout.timeout(8) { route_writer.value }
    expect(widget_identity.reload.contact_id).to eq(contact.id)
    expect(contact.reload).to have_attributes(name: 'updated by widget', owner_id: agent.id)
    expect(Conversation.where(contact_id: contact.id, inbox_id: widget.inbox.id).count).to eq(1)
  ensure
    release << true if widget_writer&.alive?
    [widget_writer, route_writer].compact.each { |writer| writer.kill if writer.alive? }
    [widget_writer, route_writer].compact.each(&:join)
    cleanup_account(account)
  end

  it 'keeps the earlier email merge target and its thread when the widget also changes phone' do
    account = create(:account)
    account.enable_features!('communication_threads')
    target = create(:contact, account: account, email: 'identified@example.test', name: 'identified')
    first_inbox = create(:channel_widget, account: account).inbox
    existing = create(:conversation, account: account, inbox: first_inbox, contact: target)
    target_thread_id = existing.reload.communication_thread.id
    visitor = create(:contact, account: account, email: nil, phone_number: nil)
    widget = create(:channel_widget, account: account)
    widget_identity = create(:contact_inbox, contact: visitor, inbox: widget.inbox)
    token = Widget::TokenService.new(payload: { source_id: widget_identity.source_id, inbox_id: widget.inbox.id }).generate_token

    contact_params = { email: target.email, phone_number: '+15551234567', name: 'visitor' }
    post '/api/v1/widget/conversations', headers: { 'X-Auth-Token' => token },
                                         params: { website_token: widget.website_token, contact: contact_params,
                                                   message: { content: 'merged channel' } }, as: :json

    expect(response).to have_http_status(:success)
    expect(widget_identity.reload.contact_id).to eq(target.id)
    expect(Contact.exists?(visitor.id)).to be(false)
    expect(target.reload).to have_attributes(name: 'identified', phone_number: '+15551234567')
    second = Conversation.find_by!(contact_id: target.id, inbox_id: widget.inbox.id)
    expect(second.communication_thread.id).to eq(target_thread_id)
    expect(second.messages.incoming.last.content).to eq('merged channel')
  ensure
    cleanup_account(account)
  end
end
