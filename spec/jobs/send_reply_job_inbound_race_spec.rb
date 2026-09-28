require 'rails_helper'
require 'timeout'

RSpec.describe SendReplyJob, 'Captain incoming/delivery commit order' do
  self.use_transactional_tests = false

  def cleanup_account(account)
    return unless account&.persisted?

    AutomationEvent.where(account_id: account.id).delete_all
    CommunicationThreadConversation.where(account_id: account.id).delete_all
    CommunicationThread.where(account_id: account.id).destroy_all
    account.destroy!
  end

  it 'commits an inbound on another channel while a claimed provider request is in flight' do
    account = create(:account)
    account.enable_features!('communication_threads')
    channel = create(:channel_widget, account: account)
    assistant = create(:captain_assistant, account: account)
    create(:captain_inbox, captain_assistant: assistant, inbox: channel.inbox)
    conversation = create(:conversation, account: account, inbox: channel.inbox, status: :pending)
    incoming = create(:message, message_type: :incoming, conversation: conversation)
    other_channel = create(:channel_widget, account: account)
    other_contact_inbox = create(:contact_inbox, contact: conversation.contact, inbox: other_channel.inbox)
    other_conversation = create(:conversation, account: account, contact: conversation.contact,
                                               inbox: other_channel.inbox, contact_inbox: other_contact_inbox)
    expect(other_conversation.reload.communication_thread).to eq(conversation.reload.communication_thread)
    reply = create(:message, message_type: :outgoing, conversation: conversation, sender: assistant,
                             additional_attributes: {
                               'captain_delivery_fence' => {
                                 'assistant_id' => assistant.id,
                                 'control_generation' => conversation.current_captain_control_generation,
                                 'trigger_message_id' => incoming.id,
                                 'kind' => 'reply'
                               }
                             })
    provider_started = Queue.new
    release_provider = Queue.new
    provider = instance_double(Messages::SendEmailNotificationService)
    allow(Messages::SendEmailNotificationService).to receive(:new).and_return(provider)
    allow(provider).to receive(:perform) do
      provider_started << true
      release_provider.pop
    end

    delivery = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { described_class.perform_now(reply.id) }
    end
    Timeout.timeout(10) { provider_started.pop }
    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        create(:message, message_type: :incoming, conversation: Conversation.find(other_conversation.id))
      end
    end
    Timeout.timeout(3) { writer.value }
    expect(delivery).to be_alive
    expect(Message.where(conversation_id: other_conversation.id).incoming.count).to eq(1)
    expect(reply.reload.additional_attributes['captain_delivery_state']).to eq('dispatching')
    expect(reply.additional_attributes['captain_delivery_claimed_at']).to be_present

    release_provider << true
    Timeout.timeout(10) { delivery.value }
    expect(reply.reload.additional_attributes['captain_delivery_state']).to eq('outcome_unknown')
    expect(reply).to be_failed
    described_class.perform_now(reply.id)
    expect(provider).to have_received(:perform).once
  ensure
    release_provider << true if delivery&.alive?
    [delivery, writer].compact.each { |thread| thread.kill if thread.alive? }
    [delivery, writer].compact.each(&:join)
    cleanup_account(account)
  end

  it 'persists an inbound without waiting for provider I/O lasting over 14 seconds' do
    stub_const('Captain::Conversation::DeliveryFenceService::PROVIDER_DISPATCH_DEADLINE', 22)
    account = create(:account)
    channel = create(:channel_widget, account: account)
    assistant = create(:captain_assistant, account: account)
    create(:captain_inbox, captain_assistant: assistant, inbox: channel.inbox)
    conversation = create(:conversation, account: account, inbox: channel.inbox, status: :pending)
    incoming = create(:message, message_type: :incoming, conversation: conversation)
    reply = create(:message, message_type: :outgoing, conversation: conversation, sender: assistant,
                             additional_attributes: {
                               'captain_delivery_fence' => {
                                 'assistant_id' => assistant.id,
                                 'control_generation' => conversation.current_captain_control_generation,
                                 'trigger_message_id' => incoming.id,
                                 'kind' => 'reply'
                               }
                             })
    provider_started = Queue.new
    provider = instance_double(Messages::SendEmailNotificationService)
    allow(Messages::SendEmailNotificationService).to receive(:new).and_return(provider)
    allow(provider).to receive(:perform) do
      provider_started << true
      sleep(15)
    end

    delivery = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { described_class.perform_now(reply.id) }
    end
    Timeout.timeout(10) { provider_started.pop }
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.transaction do
          connection.execute("SET LOCAL statement_timeout = '14s'")
          create(:message, message_type: :incoming, conversation: Conversation.find(conversation.id))
        end
      end
    end
    Timeout.timeout(3) { writer.value }
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at).to be < 3
    expect(delivery).to be_alive
    Timeout.timeout(20) { delivery.value }
    expect(Message.where(conversation_id: conversation.id).incoming.count).to eq(2)
    expect(reply.reload.additional_attributes['captain_delivery_state']).to eq('outcome_unknown')
    expect(reply).to be_failed
    described_class.perform_now(reply.id)
    expect(provider).to have_received(:perform).once
  ensure
    [delivery, writer].compact.each { |thread| thread.kill if thread.alive? }
    [delivery, writer].compact.each(&:join)
    cleanup_account(account)
  end

  it 'commits human takeover during provider I/O and records the later receipt as unknown' do
    account = create(:account)
    channel = create(:channel_widget, account: account)
    assistant = create(:captain_assistant, account: account)
    create(:captain_inbox, captain_assistant: assistant, inbox: channel.inbox)
    conversation = create(:conversation, account: account, inbox: channel.inbox, status: :pending)
    trigger = create(:message, message_type: :incoming, conversation: conversation)
    reply = create(:message, message_type: :outgoing, conversation: conversation, sender: assistant,
                             additional_attributes: {
                               'captain_delivery_fence' => {
                                 'assistant_id' => assistant.id,
                                 'control_generation' => conversation.current_captain_control_generation,
                                 'trigger_message_id' => trigger.id,
                                 'kind' => 'reply'
                               }
                             })
    provider_started = Queue.new
    release_provider = Queue.new
    provider = instance_double(Messages::SendEmailNotificationService)
    allow(Messages::SendEmailNotificationService).to receive(:new).and_return(provider)
    allow(provider).to receive(:perform) do
      provider_started << true
      release_provider.pop
      reply.update!(source_id: 'provider-receipt-1')
    end

    delivery = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { described_class.perform_now(reply.id) }
    end
    Timeout.timeout(10) { provider_started.pop }
    takeover = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Conversation.find(conversation.id).activate_captain_human_control!(source: 'manual_assignment')
      end
    end
    Timeout.timeout(3) { takeover.value }
    expect(delivery).to be_alive

    release_provider << true
    Timeout.timeout(10) { delivery.value }
    expect(reply.reload.additional_attributes).to include(
      'captain_delivery_state' => 'outcome_unknown',
      'captain_delivery_receipt_id' => 'provider-receipt-1'
    )
    described_class.perform_now(reply.id)
    expect(provider).to have_received(:perform).once
  ensure
    release_provider << true if delivery&.alive?
    [delivery, takeover].compact.each { |thread| thread.kill if thread.alive? }
    [delivery, takeover].compact.each(&:join)
    cleanup_account(account)
  end

  it 'rejects a committed inbound on an unlinked channel before its after-commit resolver runs' do
    account = create(:account)
    channel = create(:channel_widget, account: account)
    assistant = create(:captain_assistant, account: account)
    create(:captain_inbox, captain_assistant: assistant, inbox: channel.inbox)
    conversation = create(:conversation, account: account, inbox: channel.inbox, status: :pending)
    original = create(:message, message_type: :incoming, conversation: conversation)
    other_channel = create(:channel_widget, account: account)
    other_contact_inbox = create(:contact_inbox, contact: conversation.contact, inbox: other_channel.inbox)
    other_conversation = create(:conversation, account: account, contact: conversation.contact,
                                               inbox: other_channel.inbox, contact_inbox: other_contact_inbox)
    account.enable_features!('communication_threads')
    Conversations::CommunicationThreadResolver.new(conversation: conversation).perform
    expect(other_conversation.reload.communication_thread).to be_nil

    reply = create(:message, message_type: :outgoing, conversation: conversation, sender: assistant,
                             additional_attributes: {
                               'captain_delivery_fence' => {
                                 'assistant_id' => assistant.id,
                                 'control_generation' => conversation.current_captain_control_generation,
                                 'trigger_message_id' => original.id,
                                 'kind' => 'reply'
                               }
                             })
    committed = Queue.new
    finish_callback = Queue.new
    provider = instance_double(Messages::SendEmailNotificationService, perform: true)
    allow(Messages::SendEmailNotificationService).to receive(:new).and_return(provider)
    allow_any_instance_of(Message).to receive(:execute_after_create_commit_callbacks).and_wrap_original do |callback|
      if callback.receiver.content == 'M2 before link'
        committed << callback.receiver.id
        finish_callback.pop
      end
      callback.call
    end

    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        create(:message, message_type: :incoming, conversation: Conversation.find(other_conversation.id), content: 'M2 before link')
      end
    end
    incoming_id = Timeout.timeout(10) { committed.pop }
    expect(Message.exists?(incoming_id)).to be(true)
    expect(other_conversation.reload.communication_thread).to be_nil

    described_class.perform_now(reply.id)
    expect(provider).not_to have_received(:perform)
    expect(reply.reload.additional_attributes['captain_delivery_state']).to eq('cancelled')
  ensure
    finish_callback << true if writer&.alive?
    writer&.join
    cleanup_account(account)
  end
end
