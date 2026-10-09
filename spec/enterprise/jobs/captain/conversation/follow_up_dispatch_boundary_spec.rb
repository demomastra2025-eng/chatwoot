# frozen_string_literal: true

require 'rails_helper'
require 'timeout'

RSpec.describe 'Captain follow-up provider dispatch boundary', type: :job do
  self.use_transactional_tests = false

  after { CommittedRowsCleanup.truncate! }

  def in_thread(&block)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection(&block)
    end
  end

  def materialized_follow_up
    account = create(:account)
    account.enable_features!('captain_integration')
    inbox = create(:inbox, account: account)
    conversation = create(:conversation, account: account, inbox: inbox, status: :pending).reload
    assistant = create(
      :captain_assistant,
      account: account,
      config: {
        'follow_up_settings' => {
          'enabled' => true,
          'prompt' => '',
          'steps' => [{ 'mode' => 'static', 'message' => 'Checking in.', 'delay_seconds' => 60 }]
        }
      }
    )
    create(:captain_inbox, captain_assistant: assistant, inbox: inbox)
    incoming = create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      message_type: :incoming,
      content: 'Can you help?'
    )
    anchor = create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      sender: assistant,
      message_type: :outgoing,
      private: false,
      additional_attributes: { captain_ai_reply: { assistant_id: assistant.id } }
    )
    reminder = Captain::Conversation::FollowUpJob.schedule!(
      conversation: conversation,
      assistant: assistant,
      anchor_message: anchor,
      step: { index: 0, delay_seconds: 60 },
      control_fence: {
        control_generation: conversation.current_captain_control_generation,
        status_transition_id: conversation.status_transitions.maximum(:id).to_i,
        last_message_id: incoming.id
      }
    )
    reminder.mark_processing!
    message = Reminders::MessageMaterializer.new(
      reminder: reminder,
      additional_attributes: {
        'captain_follow_up' => {
          'assistant_id' => assistant.id,
          'anchor_message_id' => anchor.id,
          'step_index' => 0
        }
      }
    ).perform(
      conversation: conversation,
      sender: assistant,
      content: 'Checking in.',
      delivery_policy: nil
    )
    reminder.update!(status: :completed, completed_at: Time.current)

    [account, inbox, conversation, assistant, reminder, message]
  end

  def paused_provider
    entered = Queue.new
    release = Queue.new
    finished = Queue.new
    service = instance_double(Messages::SendEmailNotificationService)
    allow(service).to receive(:perform) do
      entered << true
      Timeout.timeout(15) { release.pop }
      finished << true
    end
    allow(Messages::SendEmailNotificationService).to receive(:new).and_return(service)

    [entered, release, finished, service]
  end

  def wait_for_signal(queue, worker, timeout: 10)
    Timeout.timeout(timeout) do
      loop do
        begin
          return queue.pop(true)
        rescue ThreadError
          unless worker.alive?
            result = worker.value
            raise "Worker exited before signaling: #{result.inspect}"
          end
          sleep 0.01
        end
      end
    end
  end

  def wait_for_blocked_writer(thread, started, finished)
    wait_for_signal(started, thread)
    sleep 0.15
    thread.value unless thread.alive?
    expect(finished).to be_empty
    expect(thread).to be_alive
  end

  it 'serializes a real staff reply behind the final provider call' do
    account, inbox, conversation, _assistant, _reminder, message = materialized_follow_up
    staff = create(:user, account: account)
    entered, release, provider_finished, provider = paused_provider
    dispatch_thread = in_thread { SendReplyJob.perform_now(message.id) }
    wait_for_signal(entered, dispatch_thread)

    staff_started = Queue.new
    staff_finished = Queue.new
    staff_thread = in_thread do
      staff_started << true
      Message.create!(
        account: Account.find(account.id),
        inbox: Inbox.find(inbox.id),
        conversation: Conversation.find(conversation.id),
        sender: User.find(staff.id),
        message_type: :outgoing,
        private: false,
        content: 'A staff member is taking over.'
      )
      staff_finished << :complete
    end
    wait_for_blocked_writer(staff_thread, staff_started, staff_finished)

    release << true
    expect(Timeout.timeout(15) { dispatch_thread.value }).not_to be_a(Exception)
    expect(Timeout.timeout(15) { staff_thread.value }).not_to be_a(Exception)
    expect(provider_finished.size).to eq(1)
    expect(provider).to have_received(:perform).once
    expect(Conversation.find(conversation.id)).to be_open
    expect(staff_finished.pop).to eq(:complete)
  ensure
    release << true if defined?(release) && release.empty?
    staff_thread&.join(2)
    dispatch_thread&.join(2)
  end

  it 'serializes an incoming public customer reply before a later retry' do
    _account, inbox, conversation, _assistant, reminder, message = materialized_follow_up
    entered, release, provider_finished, provider = paused_provider
    dispatch_thread = in_thread do
      SendReplyJob.perform_now_with_follow_up_finalizer(message.id) do
        reminder.mark_delivery_dispatched!(message.id, stage: 'retry_scheduled')
      end
    end
    wait_for_signal(entered, dispatch_thread)

    reply_started = Queue.new
    reply_finished = Queue.new
    contact = Contact.find(conversation.contact_id)
    reply_thread = in_thread do
      reply_started << true
      Message.create!(
        account: Account.find(conversation.account_id),
        inbox: Inbox.find(inbox.id),
        conversation: Conversation.find(conversation.id),
        sender: Contact.find(contact.id),
        message_type: :incoming,
        private: false,
        content: 'I have another question.'
      )
      reply_finished << :complete
    end
    wait_for_blocked_writer(reply_thread, reply_started, reply_finished)

    release << true
    expect(Timeout.timeout(15) { dispatch_thread.value }).not_to be_a(Exception)
    expect(Timeout.timeout(15) { reply_thread.value }).not_to be_a(Exception)
    expect(reply_finished.pop).to eq(:complete)

    SendReplyJob.perform_now(message.id)

    expect(provider_finished.size).to eq(1)
    expect(provider).to have_received(:perform).once
    expect(reminder.reload.captain_follow_up_delivery_suppressed?).to be(true)
  ensure
    release << true if defined?(release) && release.empty?
    reply_thread&.join(2)
    dispatch_thread&.join(2)
  end

  it 'serializes requested inbox settings and detach/reassignment behind provider dispatch' do
    account, inbox, _conversation, assistant, _reminder, message = materialized_follow_up
    assignment = CaptainInbox.find_by!(inbox_id: inbox.id, captain_assistant_id: assistant.id)
    replacement = create(:captain_assistant, account: account)
    entered, release, provider_finished, provider = paused_provider
    dispatch_thread = in_thread { SendReplyJob.perform_now(message.id) }
    wait_for_signal(entered, dispatch_thread)

    writer_started = Queue.new
    writer_finished = Queue.new
    writer_thread = in_thread do
      writer_started << true
      CaptainInbox.find(assignment.id).update!(auto_reply_mode: 'working_hours')
      CaptainInbox.find(assignment.id).destroy!
      CaptainInbox.create!(
        captain_assistant_id: replacement.id,
        inbox_id: inbox.id
      )
      writer_finished << :complete
    end
    wait_for_blocked_writer(writer_thread, writer_started, writer_finished)

    release << true
    expect(Timeout.timeout(15) { dispatch_thread.value }).not_to be_a(Exception)
    expect(Timeout.timeout(15) { writer_thread.value }).not_to be_a(Exception)
    expect(provider_finished.size).to eq(1)
    expect(provider).to have_received(:perform).once
    expect(writer_finished.pop).to eq(:complete)
    expect(CaptainInbox.find_by!(inbox_id: inbox.id).captain_assistant_id).to eq(replacement.id)
  ensure
    release << true if defined?(release) && release.empty?
    writer_thread&.join(2)
    dispatch_thread&.join(2)
  end

  it 'suppresses dispatch when the inbox assignment was removed first' do
    _account, inbox, _conversation, assistant, reminder, message = materialized_follow_up
    CaptainInbox.find_by!(inbox_id: inbox.id, captain_assistant_id: assistant.id).destroy!
    provider = instance_double(Messages::SendEmailNotificationService, perform: true)
    allow(Messages::SendEmailNotificationService).to receive(:new).and_return(provider)

    SendReplyJob.perform_now(message.id)

    expect(provider).not_to have_received(:perform)
    expect(reminder.reload).to be_captain_follow_up_delivery_suppressed
    expect(message.reload).to be_failed
  end

  it 'serializes account and assistant disables behind the same final provider call' do
    account, _inbox, _conversation, assistant, _reminder, message = materialized_follow_up
    entered, release, provider_finished, provider = paused_provider
    dispatch_thread = in_thread { SendReplyJob.perform_now(message.id) }
    wait_for_signal(entered, dispatch_thread)

    account_started = Queue.new
    account_finished = Queue.new
    account_thread = in_thread do
      account_started << true
      Account.find(account.id).disable_features!('captain_integration')
      account_finished << :complete
    end

    assistant_started = Queue.new
    assistant_finished = Queue.new
    assistant_thread = in_thread do
      assistant_started << true
      record = Captain::Assistant.find(assistant.id)
      config = record.config.to_h.deep_dup
      config['follow_up_settings']['enabled'] = false
      record.update!(config: config)
      assistant_finished << :complete
    end

    wait_for_blocked_writer(account_thread, account_started, account_finished)
    wait_for_blocked_writer(assistant_thread, assistant_started, assistant_finished)

    release << true
    expect(Timeout.timeout(15) { dispatch_thread.value }).not_to be_a(Exception)
    expect(Timeout.timeout(15) { account_thread.value }).not_to be_a(Exception)
    expect(Timeout.timeout(15) { assistant_thread.value }).not_to be_a(Exception)
    expect(provider_finished.size).to eq(1)
    expect(provider).to have_received(:perform).once
    expect(Account.find(account.id).feature_enabled?('captain_integration')).to be(false)
    expect(Captain::Assistant.find(assistant.id).config.dig('follow_up_settings', 'enabled')).to be(false)
    expect(account_finished.pop).to eq(:complete)
    expect(assistant_finished.pop).to eq(:complete)
  ensure
    release << true if defined?(release) && release.empty?
    account_thread&.join(2)
    assistant_thread&.join(2)
    dispatch_thread&.join(2)
  end
end
