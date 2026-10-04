# frozen_string_literal: true

require 'rails_helper'
require 'timeout'

RSpec.describe 'voice handoff and Captain follow-up dispatch lock order' do
  self.use_transactional_tests = false

  after { CommittedRowsCleanup.truncate! }

  def in_thread(&block)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection(&block)
    end
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

  it 'releases the transaction-scoped assignment fence after a real PostgreSQL statement abort' do
    channel = create(:channel_voice, :sipuni)
    account = channel.account
    inbox = channel.inbox
    conversation = create(:conversation, account: account, inbox: inbox)
    Telephony::NumberBinding.sync_from_voice_channel!(channel)
    number_binding = inbox.reload.telephony_number_binding
    call_session = create(
      :telephony_call_session,
      account: account,
      conversation: conversation,
      inbox: inbox,
      number_binding: number_binding,
      provider: 'sipuni',
      external_call_ref: 'statement-abort-assignment-lock',
      status: 'in_progress'
    )
    capability = Telephony::AiVoice::ToolCapability.issue(
      call_session: call_session,
      runtime_session_id: 'statement-abort-runtime',
      runtime_engine: 'pipecat',
      assistant_id: nil,
      tools: [{ name: 'create_note' }]
    )
    service = Telephony::AiVoice::ToolExecutionService.new(
      tool_name: 'create_note',
      payload: {
        account_id: account.id,
        call_session_id: call_session.id,
        call_ref: call_session.external_call_ref,
        conversation_id: conversation.id,
        inbox_id: inbox.id,
        runtime_session_id: 'statement-abort-runtime',
        runtime_engine: 'pipecat',
        tool_capability: capability,
        tool_call_id: 'statement-abort-create-note',
        arguments: { content: 'A note rolled back with the aborted statement.' }
      }
    )
    dispatch_service = service.send(:dispatch_service)
    allow(dispatch_service).to receive(:perform).and_wrap_original do |original|
      original.call
      ActiveRecord::Base.connection.execute('SELECT 1 / 0')
    end

    expect { service.perform }.to raise_error(ActiveRecord::StatementInvalid)
    expect(account.telephony_events.find_by!(event_type: Telephony::AiVoice::ToolExecutionService::EVENT_TYPE))
      .to have_attributes(error_message: 'TOOL_EXECUTION_OUTCOME_UNKNOWN')
    expect(conversation.messages.where(private: true)).not_to exist

    lock_id = Telephony::AiVoice::AssistantAssignmentLock.send(:lock_id_for, inbox.id)
    writer_connection = ActiveRecord::Base.connection_pool.checkout
    acquired = writer_connection.transaction(requires_new: true) do
      writer_connection.select_value("SELECT pg_try_advisory_xact_lock(#{lock_id})")
    end
    expect(acquired).to be(true)
  ensure
    ActiveRecord::Base.connection_pool.checkin(writer_connection) if writer_connection
  end

  it 'serializes a WhatsApp voice handoff before follow-up provider dispatch without deadlock' do
    channel = create(
      :channel_whatsapp,
      provider: 'whatsapp_cloud',
      validate_provider_config: false,
      sync_templates: false
    )
    account = channel.account
    account.enable_features!('captain_integration')
    inbox = channel.inbox
    contact = create(:contact, account: account, phone_number: '+123456789')
    contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox, source_id: '123456789')
    conversation = create(
      :conversation,
      account: account,
      inbox: inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      status: :pending
    )
    assistant = create(
      :captain_assistant,
      account: account,
      config: {
        'follow_up_settings' => {
          'enabled' => true,
          'prompt' => '',
          'steps' => [
            { 'mode' => 'static', 'message' => 'Checking in.', 'delay_seconds' => 60 },
            { 'mode' => 'static', 'message' => 'One more thought.', 'delay_seconds' => 120 }
          ]
        }
      }
    )
    create(:captain_inbox, captain_assistant: assistant, inbox: inbox)
    number_binding = create(:telephony_number_binding, account: account, inbox: inbox)
    create(
      :telephony_routing_policy,
      account: account,
      number_binding: number_binding,
      ai_voice_settings: {
        'manager_handoff_mode' => 'callback',
        'callback_message' => 'A manager will call you back.'
      }
    )
    call_session = create(
      :telephony_call_session,
      account: account,
      conversation: conversation,
      inbox: inbox,
      contact: contact,
      number_binding: number_binding,
      provider: 'whatsapp_cloud',
      external_call_ref: 'whatsapp:wacid-lock-order',
      status: 'in_progress'
    )

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
    fence = {
      control_generation: conversation.current_captain_control_generation,
      status_transition_id: conversation.status_transitions.maximum(:id).to_i,
      last_message_id: incoming.id
    }
    reminder = Captain::Conversation::FollowUpJob.schedule!(
      conversation: conversation,
      assistant: assistant,
      anchor_message: anchor,
      step: { index: 0, delay_seconds: 60 },
      control_fence: fence
    )
    reminder.mark_processing!
    message = Reminders::MessageMaterializer.new(
      reminder: reminder,
      additional_attributes: {
        'captain_follow_up' => {
          'assistant_id' => assistant.id,
          'anchor_message_id' => anchor.id,
          'step_index' => 0,
          'control_fence' => fence
        }
      }
    ).perform(
      conversation: conversation,
      sender: assistant,
      content: 'Checking in.',
      delivery_policy: nil
    )
    reminder.update!(status: :completed, completed_at: Time.current)

    runtime_session_id = 'whatsapp-lock-order-runtime'
    runtime_engine = 'pipecat'
    capability = Telephony::AiVoice::ToolCapability.issue(
      call_session: call_session,
      runtime_session_id: runtime_session_id,
      runtime_engine: runtime_engine,
      assistant_id: assistant.id,
      tools: [{ name: 'request_transfer' }]
    )
    voice_execution = Telephony::AiVoice::ToolExecutionService.new(
      tool_name: 'request_transfer',
      payload: {
        account_id: account.id,
        call_session_id: call_session.id,
        call_ref: call_session.external_call_ref,
        conversation_id: conversation.id,
        inbox_id: inbox.id,
        assistant_id: assistant.id,
        runtime_session_id: runtime_session_id,
        runtime_engine: runtime_engine,
        tool_capability: capability,
        tool_call_id: 'whatsapp-lock-order-handoff',
        arguments: { reason: 'The caller requested a manager.' }
      }
    )

    provider = instance_double(Whatsapp::SendOnWhatsappService, perform: true)
    allow(Whatsapp::SendOnWhatsappService).to receive(:new).and_return(provider)
    assignment_entered = Queue.new
    release_voice = Queue.new
    allow(Telephony::AiVoice::AssistantAssignmentLock).to receive(:acquire!).and_wrap_original do |original, inbox_id|
      original.call(inbox_id)
      if Thread.current[:pause_voice_assignment]
        assignment_entered << inbox_id
        Timeout.timeout(15) { release_voice.pop }
      end
    end

    voice_thread = in_thread do
      Thread.current[:pause_voice_assignment] = true
      voice_execution.perform
    end
    wait_for_signal(assignment_entered, voice_thread)

    dispatch_started = Queue.new
    follow_up_thread = in_thread do
      dispatch_started << true
      SendReplyJob.perform_now(message.id)
    end
    Timeout.timeout(10) { dispatch_started.pop }
    sleep 0.15
    expect(follow_up_thread).to be_alive
    expect(provider).not_to have_received(:perform)

    release_voice << true
    results = [
      Timeout.timeout(20) { voice_thread.value },
      Timeout.timeout(20) { follow_up_thread.value }
    ]

    expect(results).to all(satisfy { |result| !result.is_a?(Exception) })
    expect(results.first).to include('action' => 'callback_handoff', 'status' => 'accepted')
    expect(conversation.reload).to be_open
    expect(message.reload).to be_failed
    expect(provider).not_to have_received(:perform)
  ensure
    release_voice << true if defined?(release_voice) && release_voice.empty?
    follow_up_thread&.join(2)
    voice_thread&.join(2)
  end
end
