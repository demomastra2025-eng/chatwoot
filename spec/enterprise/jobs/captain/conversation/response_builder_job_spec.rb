require 'rails_helper'

RSpec.describe Captain::Conversation::ResponseBuilderJob, type: :job do
  let(:account) { create(:account, custom_attributes: { plan_name: 'startups' }) }
  let(:inbox) { create(:inbox, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }

  # The handoff message is one account-level Captain setting shared by every agent.
  def save_account_handoff_message(enabled: true, mode: 'fixed', text: '', instruction: '')
    configure_notice(account, 'handoff_message', enabled: enabled, mode: mode, text: text, instruction: instruction)
  end

  describe '#perform' do
    let(:conversation) { create(:conversation, inbox: inbox, account: account, status: :pending) }
    let(:agent_runner_service) { instance_double(Captain::Assistant::AgentRunnerService) }

    before do
      account.enable_features!('captain_integration', 'captain_tasks')
      create(:captain_inbox, captain_assistant: assistant, inbox: inbox)
      create(:message, conversation: conversation, content: 'Hello', message_type: :incoming)
      allow(Captain::Assistant::AgentRunnerService).to receive(:new).and_return(agent_runner_service)
      allow(agent_runner_service).to receive(:generate_response).and_return({ 'response' => 'Hey, welcome to Captain V2' })
      allow(Captain::Conversation::TypingIndicatorService).to receive(:turn_on)
      allow(Captain::Conversation::TypingIndicatorService).to receive(:turn_off)
    end

    it 'rejects a queued response when AI is disabled for the channel' do
      inbox.captain_inbox.update!(ai_enabled: false)
      job = described_class.new
      job.instance_variable_set(:@conversation, conversation)
      job.instance_variable_set(:@assistant, assistant)

      expect(job.send(:conversation_eligible_for_response?)).to be false
    end

    def create_sendable_document(name: 'Price list', filename: 'price-list.pdf')
      build(:captain_document, assistant: assistant, account: account, name: name, external_link: nil, status: :available).tap do |document|
        document.pdf_file.attach(
          io: StringIO.new('%PDF-1.4 file'),
          filename: filename,
          content_type: 'application/pdf'
        )
        document.save!
      end
    end

    def document_artifact_payload(document)
      document.reload

      Captain::Tools::DocumentArtifactToken.encode(
        account_id: account.id,
        assistant_id: assistant.id,
        document_id: document.id,
        blob_id: document.sendable_file_blob_id,
        status: document.status,
        document_fingerprint: document.artifact_fingerprint
      )
    end

    def list_documents_trace(*documents)
      { 'version' => 1, 'tool_steps' => [list_documents_finish_step(documents)] }
    end

    def list_documents_finish_step(documents)
      {
        'event' => 'finish',
        'tool_name' => 'list_captain_documents',
        'output' => {
          'success' => true,
          'message' => JSON.generate('action' => 'list_captain_documents', 'documents' => documents.map { |document| list_document_entry(document) })
        }
      }
    end

    def list_document_entry(document)
      {
        'document_id' => document.id,
        'name' => document.name,
        'source_mode' => document.source_mode,
        'status' => document.status,
        'content_type' => document.content_type,
        'file_size' => document.file_size,
        'sendable' => true,
        'filename' => document.sendable_filename,
        'artifact_id' => document_artifact_payload(document)
      }
    end

    it 'does not let the primary model classify a completed outcome' do
      assistant.update!(
        config: assistant.config.to_h.deep_merge(
          'outcome_reason_settings' => {
            'handoff_reasons' => [
              { 'id' => 'billing_queue', 'label' => 'Support', 'active' => true },
              { 'id' => 'technical_queue', 'label' => 'Support', 'active' => true }
            ]
          }
        )
      )
      job = described_class.new
      job.instance_variable_set(:@assistant, assistant)
      job.instance_variable_set(:@response, {
                                  'handoff_outcome_reason_id' => 'technical_queue',
                                  'handoff_status_reason' => 'Support'
                                })

      expect(job.send(:handoff_status_reason)).to eq(Captain::OutcomeReasonConfig.new(assistant).pending_label)
      expect(job.send(:handoff_transition_audit)[:metadata]).not_to have_key(:outcome_reason_id)
    end

    it 'persists a fenced first follow-up with a normal public AI reply' do
      account.enable_features!('captain_integration')
      assistant.update!(
        config: {
          'follow_up_settings' => {
            'enabled' => true,
            'prompt' => '',
            'steps' => [{ 'mode' => 'static', 'message' => 'Checking whether you still need help.', 'delay_seconds' => 60 }]
          }
        }
      )

      described_class.perform_now(conversation, assistant)

      reply = conversation.messages.outgoing.where(sender: assistant, private: false).sole
      expect(reply.additional_attributes.to_h).to include('captain_ai_reply' => { 'assistant_id' => assistant.id })
      reminder = account.reminders.captain_follow_up.sole
      expect(reminder.target_conversation_id).to eq(conversation.id)
      expect(reminder.metadata.dig('captain_follow_up', 'control_fence')).to include(
        'control_generation' => conversation.current_captain_control_generation,
        'status_transition_id' => conversation.status_transitions.maximum(:id).to_i,
        'last_message_id' => conversation.messages.incoming.maximum(:id)
      )
    end

    it 'schedules a configured council follow-up for an answered part' do
      assistant.update!(
        config: {
          'follow_up_settings' => {
            'enabled' => true,
            'steps' => [{ 'mode' => 'static', 'message' => 'Still need help?', 'delay_seconds' => 60 }]
          }
        }
      )
      part_ref = { 'id' => SecureRandom.uuid, 'version' => 1 }
      Captain::Conversation::AgentSession.new(entry: assistant, conversation: conversation).change do |session|
        session['parts'] = [part_ref.merge('executor_agent_id' => assistant.id, 'state' => 'answered')]
      end
      reply = create(:message, conversation: conversation, sender: assistant, message_type: :outgoing, content: 'Done')
      job = described_class.new
      job.instance_variable_set(:@conversation, conversation)
      job.instance_variable_set(:@assistant, assistant)
      job.instance_variable_set(:@response, { 'part_refs' => [part_ref] })

      expect(Captain::Conversation::FollowUpJob).to receive(:schedule!).with(
        conversation: conversation, assistant: assistant, anchor_message: reply,
        step: { index: 0, delay_seconds: 60 }, control_fence: {}, part_ref: part_ref
      )

      job.send(:schedule_council_follow_ups, reply)
    end

    it 'records the version of the part with each delivery, so that the action of a follow-up version is not hidden by an earlier question' do
      part_id = SecureRandom.uuid
      question = { 'message_id' => 1, 'content' => 'На какое время вас записать?', 'at' => Time.current.iso8601, 'version' => 1 }
      session = Captain::Conversation::AgentSession.new(entry: assistant, conversation: conversation)
      session.change do |data|
        data['parts'] = [{ 'id' => part_id, 'version' => 2, 'executor_agent_id' => assistant.id, 'state' => 'done', 'acted' => true,
                           'delivered' => [question] }]
      end
      expect(Captain::Runtime::PartRegistry.undelivered_outcomes(session.read['parts']).pluck('id')).to eq([part_id])
      reply = create(:message, conversation: conversation, sender: assistant, message_type: :outgoing, content: 'Вы записаны на 11:00.')
      job = described_class.new
      job.instance_variable_set(:@conversation, conversation)
      job.instance_variable_set(:@assistant, assistant)
      job.instance_variable_set(:@response, { 'part_refs' => [{ 'id' => part_id, 'version' => 2 }] })

      job.send(:record_part_delivery, reply)

      parts = session.read['parts']
      expect(parts.first['delivered'].pluck('version', 'message_id')).to eq([[1, 1], [2, reply.id]])
      expect(Captain::Runtime::PartRegistry.undelivered_outcomes(parts)).to be_empty
    end

    it 'uses Captain::Assistant::AgentRunnerService with runtime callbacks' do
      expect(Captain::Assistant::AgentRunnerService).to receive(:new).with(
        assistant: assistant,
        conversation: conversation,
        incoming_message_id: conversation.messages.incoming.last.id,
        callbacks: hash_including(
          on_agent_thinking: kind_of(Proc),
          on_tool_start: kind_of(Proc),
          on_tool_complete: kind_of(Proc)
        ),
        response_fence: {
          control_generation: 0,
          status_transition_id: conversation.messages.incoming.last.additional_attributes.fetch('captain_status_transition_id'),
          last_message_id: conversation.messages.incoming.last.id
        }
      ).and_return(agent_runner_service)

      described_class.perform_now(conversation, assistant)

      expect(conversation.messages.last.content).to eq('Hey, welcome to Captain V2')
    end

    it 'turns the manager typing indicator on and off around response generation' do
      described_class.perform_now(conversation, assistant)

      expect(Captain::Conversation::TypingIndicatorService).to have_received(:turn_on).with(
        conversation: conversation,
        assistant: assistant
      ).at_least(:once)
      expect(Captain::Conversation::TypingIndicatorService).to have_received(:turn_off).with(
        conversation: conversation,
        assistant: assistant
      ).once
    end

    it 'does not issue a standalone conversation-status query before responding' do
      queries = []
      observer = ->(_name, _start, _finish, _id, payload) { queries << payload[:sql] }
      ActiveSupport::Notifications.subscribed(observer, 'sql.active_record') do
        described_class.perform_now(conversation, assistant)
      end

      expect(conversation.messages.outgoing.where(sender: assistant).count).to eq(1)
      expect(queries.grep(/SELECT "conversations"\."status" FROM/)).to be_empty
    end

    it 'does not delete a newer buffer installed while the completed response clears its old token' do
      incoming = conversation.messages.incoming.last
      key = format(Redis::Alfred::CAPTAIN_MESSAGE_BUFFER_STATE, conversation_id: conversation.id)
      old_state = { token: 'old-run', assistant_id: assistant.id, last_message_id: incoming.id, control_generation: 0 }.to_json
      new_state = { token: 'new-run', assistant_id: assistant.id, last_message_id: incoming.id, control_generation: 0 }.to_json
      Redis::Alfred.set(key, old_state, ex: 60)
      allow(Redis::Alfred).to receive(:delete_if_value).and_wrap_original do |method, target, expected|
        Redis::Alfred.set(key, new_state, ex: 60) if target == key
        method.call(target, expected)
      end

      described_class.perform_now(conversation, assistant, buffer_token: 'old-run', expected_last_message_id: incoming.id)

      expect(conversation.messages.outgoing.where(sender: assistant).count).to eq(1)
      expect(Redis::Alfred.get(key)).to eq(new_state)
    ensure
      Redis::Alfred.delete(key) if defined?(key)
    end

    it 'passes message history to the agent runner service' do
      expect(agent_runner_service).to receive(:generate_response).with(
        message_history: [{ content: 'Hello', role: 'user' }]
      )

      described_class.perform_now(conversation, assistant)
    end

    it 'passes linked-channel history from the communication thread' do
      thread = create(:communication_thread, account: account, contact: conversation.contact)
      sibling = create(:conversation, account: account, contact: conversation.contact, status: :pending)
      create(:communication_thread_conversation, communication_thread: thread, conversation: conversation)
      create(:communication_thread_conversation, communication_thread: thread, conversation: sibling)
      [conversation, sibling].each do |linked_conversation|
        linked_conversation.association(:communication_thread_conversation).reset
        linked_conversation.association(:communication_thread).reset
      end
      historical_question = build(
        :message,
        conversation: sibling,
        content: 'Question from WhatsApp',
        message_type: :incoming,
        created_at: 2.minutes.ago
      )
      historical_question.skip_runtime_events = true
      historical_question.save!
      create(
        :message,
        conversation: sibling,
        content: 'Earlier Captain answer',
        message_type: :outgoing,
        sender: assistant,
        created_at: 1.minute.ago
      )
      conversation.messages.incoming.last.update!(created_at: Time.current)

      expect(agent_runner_service).to receive(:generate_response).with(
        message_history: [
          { content: 'Question from WhatsApp', role: 'user' },
          { content: 'Earlier Captain answer', role: 'assistant' },
          { content: 'Hello', role: 'user' }
        ]
      )

      described_class.perform_now(conversation.reload, assistant)
    end

    it 'answers all three independent channels of a contact without sibling requests cancelling their replies' do
      thread = create(:communication_thread, account: account, contact: conversation.contact)
      channels = [conversation] + Array.new(2) do
        sibling_inbox = create(:inbox, account: account)
        create(:captain_inbox, inbox: sibling_inbox, captain_assistant: assistant)
        create(:conversation, account: account, inbox: sibling_inbox, contact: conversation.contact, status: :pending)
      end
      channels.each do |candidate|
        create(:communication_thread_conversation, communication_thread: thread, conversation: candidate)
        candidate.association(:communication_thread_conversation).reset
        candidate.association(:communication_thread).reset
      end
      triggers = channels.each_with_index.map do |candidate, index|
        create(:message, conversation: candidate, message_type: :incoming, content: "Request #{index}", skip_runtime_events: true)
      end

      channels.zip(triggers).each do |candidate, trigger|
        described_class.perform_now(candidate.reload, assistant, expected_last_message_id: trigger.id)
      end

      channels.each do |candidate|
        expect(candidate.messages.outgoing.where(private: false).pluck(:content)).to eq(['Hey, welcome to Captain V2'])
      end
      expect(agent_runner_service).to have_received(:generate_response).exactly(3).times
    end

    it 'builds a second-turn history after trace-free legacy and static follow-up replies' do
      conversation.messages.destroy_all
      create(:message, conversation: conversation, content: 'Original question', message_type: :incoming)
      create(
        :message,
        conversation: conversation,
        content: 'Earlier Captain reply',
        message_type: :outgoing,
        sender: assistant,
        additional_attributes: { captain_ai_reply: { assistant_id: assistant.id } }
      )
      create(
        :message,
        conversation: conversation,
        content: 'Static follow-up',
        message_type: :outgoing,
        sender: assistant,
        additional_attributes: {
          'captain_follow_up' => {
            'assistant_id' => assistant.id,
            'step_index' => 0
          }
        }
      )
      create(:message, conversation: conversation, content: 'I still have a question', message_type: :incoming)

      expect(agent_runner_service).to receive(:generate_response).with(
        message_history: [
          { content: 'Original question', role: 'user' },
          { content: 'Earlier Captain reply', role: 'assistant' },
          { content: 'Static follow-up', role: 'assistant' },
          { content: 'I still have a question', role: 'user' }
        ]
      )

      described_class.perform_now(conversation, assistant)
    end

    it 'infers the agent key from a transfer in the captain trace under the new and the former tool name' do
      conversation.messages.destroy_all
      create(:message, conversation: conversation, content: 'Start', message_type: :incoming)
      %w[transfer_to_agent_35 handoff_to_assistant_36].each do |tool_name|
        create(
          :message,
          conversation: conversation,
          content: "Answer after #{tool_name}",
          message_type: :outgoing,
          sender: assistant,
          additional_attributes: { captain_trace: { version: 1, tool_steps: [{ event: 'complete', tool_name: tool_name }] } }
        )
      end
      create(:message, conversation: conversation, content: 'Continue please', message_type: :incoming)

      expect(agent_runner_service).to receive(:generate_response).with(
        message_history: [
          { content: 'Start', role: 'user' },
          { content: 'Answer after transfer_to_agent_35', role: 'assistant', agent_name: 'assistant_35' },
          { content: 'Answer after handoff_to_assistant_36', role: 'assistant', agent_name: 'assistant_36' },
          { content: 'Continue please', role: 'user' }
        ]
      )

      described_class.perform_now(conversation, assistant)
    end

    it 'infers scenario agent_name from captain trace when legacy messages are missing explicit attribution' do
      conversation.messages.destroy_all
      create(
        :message,
        conversation: conversation,
        content: 'Start scenario',
        message_type: :incoming
      )
      create(
        :message,
        conversation: conversation,
        content: 'Scenario answer',
        message_type: :outgoing,
        sender: assistant,
        additional_attributes: {
          captain_trace: {
            version: 1,
            tool_steps: [
              {
                event: 'complete',
                tool_name: 'handoff_to_scenario_35_andalusiya_agent'
              }
            ]
          }
        }
      )
      create(
        :message,
        conversation: conversation,
        content: 'Continue please',
        message_type: :incoming
      )

      expect(agent_runner_service).to receive(:generate_response).with(
        message_history: [
          { content: 'Start scenario', role: 'user' },
          {
            content: 'Scenario answer',
            role: 'assistant',
            agent_name: 'scenario_35_andalusiya_agent'
          },
          { content: 'Continue please', role: 'user' }
        ]
      )

      described_class.perform_now(conversation, assistant)
    end

    it 'generates and processes a response' do
      described_class.perform_now(conversation, assistant)

      expect(conversation.messages.count).to eq(2)
      expect(conversation.messages.outgoing.count).to eq(1)
      expect(conversation.messages.last.content).to eq('Hey, welcome to Captain V2')
    end

    it 'increments usage response' do
      described_class.perform_now(conversation, assistant)

      account.reload
      expect(account.usage_limits[:captain][:responses][:consumed]).to eq(1)
    end

    it 'does not send a response when the conversation is no longer pending' do
      conversation.open!

      expect(agent_runner_service).not_to receive(:generate_response)

      expect do
        described_class.perform_now(conversation, assistant)
      end.not_to(change { conversation.messages.outgoing.count })
    end

    it 'does not respond to open conversations even when the old setting is enabled' do
      inbox.captain_inbox.update!(reply_to_open_conversations: true)
      conversation.open!

      expect(agent_runner_service).not_to receive(:generate_response)
      expect do
        described_class.perform_now(conversation, assistant)
      end.not_to(change { conversation.messages.outgoing.count })
    end

    it 'skips a bufferless stale job when a newer incoming message exists' do
      stale_last_message_id = conversation.messages.incoming.last.id
      create(:message, conversation: conversation, content: 'Newer incoming', message_type: :incoming)

      expect(agent_runner_service).not_to receive(:generate_response)

      expect do
        described_class.perform_now(conversation, assistant, expected_last_message_id: stale_last_message_id)
      end.not_to(change { conversation.messages.outgoing.count })
    end

    it 'does not persist a bufferless response if a newer incoming arrives during generation' do
      expected_last_message_id = conversation.messages.incoming.last.id
      expect(agent_runner_service).to receive(:generate_response) do
        create(:message, conversation: conversation, content: 'Interrupting incoming', message_type: :incoming)
        { 'response' => 'Late stale response' }
      end

      expect do
        described_class.perform_now(conversation, assistant, expected_last_message_id: expected_last_message_id)
      end.not_to(change { conversation.messages.outgoing.count })
    end

    it 'does not start a response while human control is active' do
      conversation.activate_captain_human_control!(source: 'agent_reply')
      expect(agent_runner_service).not_to receive(:generate_response)

      described_class.perform_now(conversation, assistant)

      expect(conversation.messages.outgoing.where(sender: assistant)).to be_empty
    end

    it 'does not publish an AI response when a human replies during generation' do
      agent = create(:user, account: account, role: :agent)
      expected_generation = conversation.captain_control_generation
      allow(Llm::EventBus).to receive(:publish)
      allow(agent_runner_service).to receive(:generate_response) do
        create(:message, conversation: conversation, message_type: :outgoing, sender: agent, account: account, inbox: inbox)
        { 'response' => 'Late AI response' }
      end

      described_class.perform_now(conversation, assistant, expected_control_generation: expected_generation)

      expect(conversation.reload.status).to eq('open')
      expect(conversation.messages.outgoing.where(sender: assistant)).to be_empty
      expect(Llm::EventBus).to have_received(:publish).with(
        'captain.run.fenced',
        hash_including(reason: 'human_response_committed', stage: 'response_processing')
      )
    end

    it 'publishes a response-processing fence when the conversation is resolved during generation' do
      allow(Llm::EventBus).to receive(:publish)
      allow(agent_runner_service).to receive(:generate_response) do
        conversation.update!(status: :resolved)
        { 'response' => 'Late AI response' }
      end

      expect do
        described_class.perform_now(conversation, assistant)
      end.not_to(change { conversation.messages.outgoing.where(sender: assistant).count })

      expect(account.reload.usage_limits[:captain][:responses][:consumed]).to eq(0)
      expect(Llm::EventBus).to have_received(:publish).with(
        'captain.run.fenced',
        hash_including(reason: 'status_changed', stage: 'response_processing')
      )
    end

    it 'does not publish after a human reply commits while its ownership callback is waiting' do
      trigger_message = conversation.messages.incoming.last
      allow(agent_runner_service).to receive(:generate_response) do
        create(:message, conversation: conversation, message_type: :outgoing, sender: create(:user, account: account), account: account, inbox: inbox)
        conversation.update!(captain_control_state: 'ai', captain_control_generation: 0, status: :pending)
        { 'response' => 'Late AI response' }
      end

      described_class.perform_now(conversation, assistant, expected_last_message_id: trigger_message.id)

      expect(conversation.reload.captain_control_state).to eq('ai')
      expect(conversation.messages.outgoing.where(sender: assistant)).to be_empty
    end

    it 'locks the conversation before thread ownership and rechecks before publishing an AI response' do
      expect(conversation).to receive(:with_lock).at_least(:once).ordered.and_call_original
      expect(conversation).to receive(:with_captain_control_lock).ordered.and_call_original

      described_class.perform_now(conversation, assistant)

      expect(conversation.messages.outgoing.where(sender: assistant)).not_to be_empty
    end

    it 'does not revive a queued run after control returns to Captain in a newer generation' do
      agent = create(:user, account: account, role: :agent)
      stale_generation = conversation.captain_control_generation
      conversation.activate_captain_human_control!(source: 'agent_reply', actor: agent)
      Conversations::StatusTransitionService.new(
        conversation: conversation,
        params: { status: 'pending' },
        actor: agent,
        source: 'api'
      ).perform
      expect(agent_runner_service).not_to receive(:generate_response)

      described_class.perform_now(conversation, assistant, expected_control_generation: stale_generation)

      expect(conversation.messages.outgoing.where(sender: assistant)).to be_empty
    end

    it 'does not revive a queued run after pending becomes open and pending again' do
      incoming = conversation.messages.incoming.last
      conversation.stamp_captain_control_generation!(incoming)
      Conversations::StatusTransitionService.new(conversation: conversation, params: { status: 'open' }, source: 'system').perform
      Conversations::StatusTransitionService.new(conversation: conversation, params: { status: 'pending' }, source: 'system').perform
      expect(conversation.reload).to be_pending
      expect(agent_runner_service).not_to receive(:generate_response)

      described_class.perform_now(conversation, assistant, expected_last_message_id: incoming.id)

      expect(conversation.messages.outgoing.where(sender: assistant)).to be_empty
    end

    context 'when the incoming message was stamped by the previous release' do
      let(:incoming) { conversation.messages.incoming.last }

      before do
        legacy_stamp = incoming.reload.additional_attributes.to_h.except('captain_status_transition_id')
        incoming.update_columns(additional_attributes: legacy_stamp.merge('captain_control_generation' => 0)) # rubocop:disable Rails/SkipsModelValidations
      end

      it 'replies without an epoch fence instead of dropping the reply' do
        described_class.perform_now(conversation, assistant, expected_last_message_id: incoming.id)

        expect(conversation.reload.status).to eq('pending')
        expect(conversation.messages.outgoing.where(sender: assistant).pluck(:content)).to eq(['Hey, welcome to Captain V2'])
      end

      it 'hands a failed turn to people instead of leaving it silent' do
        allow(agent_runner_service).to receive(:generate_response).and_raise(StandardError, 'provider down')

        described_class.perform_now(conversation, assistant, expected_last_message_id: incoming.id)

        expect(conversation.reload.status).to eq('open')
        expect(conversation.messages.where(private: true).pluck(:content)).to eq([described_class::FAILED_TURN_HANDOFF_NOTE])
      end

      it 'still stops after a human took the conversation over' do
        agent = create(:user, account: account, role: :agent)
        create(:message, conversation: conversation, message_type: :outgoing, sender: agent, account: account, inbox: inbox, content: 'Agent here')
        expect(agent_runner_service).not_to receive(:generate_response)

        described_class.perform_now(conversation, assistant, expected_last_message_id: incoming.id)

        expect(conversation.messages.outgoing.where(sender: assistant)).to be_empty
      end
    end

    it 'skips a buffered stale job when the latest incoming no longer matches the buffer state' do
      buffer_token = SecureRandom.uuid
      expected_last_message_id = conversation.messages.incoming.last.id
      state_key = format(Redis::Alfred::CAPTAIN_MESSAGE_BUFFER_STATE, conversation_id: conversation.id)
      Redis::Alfred.set(
        state_key,
        {
          token: buffer_token,
          assistant_id: assistant.id,
          last_message_id: expected_last_message_id
        }.to_json,
        ex: 10.minutes.to_i
      )
      create(:message, conversation: conversation, content: 'Newer incoming', message_type: :incoming)

      expect(agent_runner_service).not_to receive(:generate_response)

      expect do
        described_class.perform_now(
          conversation,
          assistant,
          buffer_token: buffer_token,
          expected_last_message_id: expected_last_message_id
        )
      end.not_to(change { conversation.messages.outgoing.count })
    ensure
      Redis::Alfred.delete(state_key) if defined?(state_key)
    end

    it 'does not persist a buffered response if a newer incoming arrives during generation' do
      buffer_token = SecureRandom.uuid
      expected_last_message_id = conversation.messages.incoming.last.id
      state_key = format(Redis::Alfred::CAPTAIN_MESSAGE_BUFFER_STATE, conversation_id: conversation.id)
      Redis::Alfred.set(
        state_key,
        {
          token: buffer_token,
          assistant_id: assistant.id,
          last_message_id: expected_last_message_id
        }.to_json,
        ex: 10.minutes.to_i
      )
      expect(agent_runner_service).to receive(:generate_response) do
        create(:message, conversation: conversation, content: 'Interrupting incoming', message_type: :incoming)
        { 'response' => 'Late stale response' }
      end

      expect do
        described_class.perform_now(
          conversation,
          assistant,
          buffer_token: buffer_token,
          expected_last_message_id: expected_last_message_id
        )
      end.not_to(change { conversation.messages.outgoing.count })
    ensure
      Redis::Alfred.delete(state_key) if defined?(state_key)
    end

    it 'silently skips outgoing messages when the assistant cancels its own response' do
      allow(agent_runner_service).to receive(:generate_response).and_return(
        {
          'response' => 'response_cancelled',
          'response_cancelled' => true,
          'cancel_reason' => 'Acknowledgement does not need a reply',
          'usage' => { 'total_tokens' => 42 }
        }
      )

      expect do
        described_class.perform_now(conversation, assistant)
      end.not_to(change { conversation.messages.outgoing.count })

      expect(conversation.reload.status).to eq('pending')
      expect(account.reload.usage_limits[:captain][:responses][:consumed]).to eq(0)
    end

    it 'records an explicit suppressed outcome without public text, private error, or handoff' do
      allow(agent_runner_service).to receive(:generate_response).and_return(
        {
          'response' => '',
          'response_mode' => 'suppress',
          'response_suppressed' => true,
          'usage' => { 'total_tokens' => 42 }
        }
      )

      expect do
        described_class.perform_now(conversation, assistant)
      end.not_to(change { conversation.messages.count })

      expect(conversation.reload.status).to eq('pending')
      expect(conversation.messages.where(private: true)).to be_empty
      expect(account.reload.usage_limits[:captain][:responses][:consumed]).to eq(0)
    end

    it 'skips generation when a manager has cancelled the pending response' do
      cancellation_key = format(Redis::Alfred::CAPTAIN_RESPONSE_CANCELLATION_STATE, conversation_id: conversation.id)
      last_incoming_message_id = conversation.messages.incoming.last.id
      Redis::Alfred.set(
        cancellation_key,
        {
          assistant_id: assistant.id,
          last_message_id: last_incoming_message_id,
          cancelled_at: Time.current.iso8601
        }.to_json,
        ex: 10.minutes.to_i
      )

      expect(agent_runner_service).not_to receive(:generate_response)

      expect do
        described_class.perform_now(conversation, assistant, expected_last_message_id: last_incoming_message_id)
      end.not_to(change { conversation.messages.count })

      expect(Redis::Alfred.get(cancellation_key)).to be_nil
    ensure
      Redis::Alfred.delete(cancellation_key) if defined?(cancellation_key)
    end

    it 'does not turn typing back on when manager cancellation happens during runtime callbacks' do
      callbacks = nil
      last_incoming_message_id = conversation.messages.incoming.last.id

      allow(Captain::Assistant::AgentRunnerService).to receive(:new) do |**kwargs|
        expect(kwargs[:assistant]).to eq(assistant)
        expect(kwargs[:conversation]).to eq(conversation)
        callbacks = kwargs[:callbacks]
        agent_runner_service
      end

      allow(agent_runner_service).to receive(:generate_response) do
        Captain::Conversation::ResponseCancellationService.new(
          conversation: conversation,
          assistant: assistant
        ).perform(reason: 'Manager stopped the response')
        callbacks[:on_tool_start].call('lookup_order')
        { 'response' => 'This late answer must be ignored' }
      end

      expect do
        described_class.perform_now(conversation, assistant, expected_last_message_id: last_incoming_message_id)
      end.not_to(change { conversation.messages.count })

      expect(Captain::Conversation::TypingIndicatorService).to have_received(:turn_on).with(
        conversation: conversation,
        assistant: assistant
      ).once
      expect(Captain::Conversation::TypingIndicatorService).to have_received(:turn_off).with(
        conversation: conversation,
        assistant: assistant
      ).at_least(:once)
    end

    it 'keeps manager cancellation silent when a late runtime error is raised' do
      last_incoming_message_id = conversation.messages.incoming.last.id

      allow(agent_runner_service).to receive(:generate_response) do
        Captain::Conversation::ResponseCancellationService.new(
          conversation: conversation,
          assistant: assistant
        ).perform(reason: 'Manager stopped the response')
        raise StandardError, 'provider failed after cancellation'
      end

      expect do
        described_class.perform_now(conversation, assistant, expected_last_message_id: last_incoming_message_id)
      end.not_to(change { conversation.messages.count })

      expect(conversation.reload.status).to eq('pending')
      expect(account.reload.usage_limits[:captain][:responses][:consumed]).to eq(0)
    end

    it 'stops a fenced runtime silently without applying provider-error handoff' do
      allow(agent_runner_service).to receive(:generate_response).and_raise(
        Captain::Conversation::ControlGenerationStaleError,
        'Captain response run is stale: buffer_state_changed'
      )

      expect { described_class.perform_now(conversation, assistant) }.not_to(change { conversation.messages.count })
      expect(conversation.reload.status).to eq('pending')
      expect(account.reload.usage_limits[:captain][:responses][:consumed]).to eq(0)
    end

    it 'does not persist raw provider error details in the failure private note' do
      allow(agent_runner_service).to receive(:generate_response) do
        raise StandardError, 'RubyLLM::PaymentRequiredError: OpenRouter credits exhausted for max_tokens=4096'
      end

      described_class.perform_now(conversation, assistant)

      private_note = conversation.reload.messages.outgoing.where(private: true).last
      expect(private_note.content).to eq(
        'Automatic reply could not be generated. Handoff to human agent was triggered.'
      )
      expect(private_note.content).not_to include('RubyLLM')
      expect(private_note.content).not_to include('OpenRouter')
      expect(private_note.content).not_to include('max_tokens')
      expect(conversation.status).to eq('open')
    end

    context 'when a failed turn loses its response fence before the system handoff' do
      let(:job) { described_class.new }

      before do
        allow(agent_runner_service).to receive(:generate_response).and_raise(StandardError, 'provider down')
      end

      def expect_no_failed_turn_handoff
        expect(conversation.reload.captain_handoff_applied_at).to be_nil
        expect(conversation.messages.where(private: true, content: described_class::FAILED_TURN_HANDOFF_NOTE)).to be_empty
        expect(conversation.messages.outgoing.where(sender: assistant)).to be_empty
      end

      it 'leaves a newer customer message to its own Captain run' do
        allow(job).to receive(:handoff_failed_turn).and_wrap_original do |method|
          create(:message, conversation: conversation, content: 'One more question', message_type: :incoming)
          method.call
        end

        job.perform(conversation, assistant)

        expect(conversation.reload.status).to eq('pending')
        expect_no_failed_turn_handoff
      end

      it 'does not hand off after pending became open and pending again' do
        allow(job).to receive(:handoff_failed_turn).and_wrap_original do |method|
          Conversations::StatusTransitionService.new(conversation: conversation, params: { status: 'open' }, source: 'system').perform
          Conversations::StatusTransitionService.new(conversation: conversation, params: { status: 'pending' }, source: 'system').perform
          method.call
        end

        job.perform(conversation, assistant)

        expect(conversation.reload.status).to eq('pending')
        expect_no_failed_turn_handoff
      end

      it 'does not override a human who took the conversation over' do
        agent = create(:user, account: account, role: :agent)
        allow(job).to receive(:handoff_failed_turn).and_wrap_original do |method|
          create(:message, conversation: conversation, message_type: :outgoing, sender: agent, account: account, inbox: inbox,
                           content: 'Agent is here')
          method.call
        end

        job.perform(conversation, assistant)

        expect(conversation.reload.status).to eq('open')
        expect_no_failed_turn_handoff
      end
    end

    it 'does not act on a failed turn once the conversation is open' do
      conversation.update!(status: :open)
      allow(agent_runner_service).to receive(:generate_response).and_raise(StandardError, 'provider down')

      expect { described_class.perform_now(conversation, assistant) }.not_to(change { conversation.messages.count })
      expect(conversation.reload.captain_handoff_applied_at).to be_nil
    end

    it 'stores captain trace on the outgoing message when provided by the assistant runtime' do
      trace_payload = Captain::ToolTraceBuilder.payload([
                                                          Captain::ToolTraceBuilder.step(
                                                            tool_name: 'search_documentation',
                                                            event: 'start',
                                                            sequence: 1
                                                          ),
                                                          Captain::ToolTraceBuilder.step(
                                                            tool_name: 'search_documentation',
                                                            event: 'complete',
                                                            sequence: 2
                                                          )
                                                        ])
      allow(agent_runner_service).to receive(:generate_response).and_return(
        {
          'response' => 'Hey, welcome to Captain V2',
          'captain_trace' => trace_payload
        }
      )

      described_class.perform_now(conversation, assistant)

      expect(conversation.reload.messages.outgoing.last.additional_attributes['captain_trace']).to eq(trace_payload)
    end

    it 'normalizes malformed UTF-8 in runtime traces before persisting the outgoing message' do
      malformed_output = "custom field: \xD1".b.force_encoding(Encoding::UTF_8)
      allow(agent_runner_service).to receive(:generate_response).and_return(
        {
          'response' => 'I found the custom fields.',
          'captain_trace' => {
            'tool_steps' => [{ 'tool_name' => 'list_deal_custom_fields', 'output' => malformed_output }]
          }
        }
      )

      expect { described_class.perform_now(conversation, assistant) }.not_to raise_error

      trace = conversation.messages.outgoing.last.additional_attributes.fetch('captain_trace')
      expect(trace.dig('tool_steps', 0, 'output')).to be_valid_encoding
      expect { JSON.generate(trace) }.not_to raise_error
    end

    it 'stores the scenario title in the existing agentName display field while preserving the runtime agent_name key' do
      scenario = create(
        :captain_scenario,
        assistant: assistant,
        account: account,
        title: 'Andalusiya Premium Reception Scenario'
      )

      allow(agent_runner_service).to receive(:generate_response).and_return(
        {
          'response' => 'Handled by scenario',
          'agent_name' => scenario.handoff_key
        }
      )

      described_class.perform_now(conversation, assistant)

      attrs = conversation.reload.messages.outgoing.last.additional_attributes
      expect(attrs['agent_name']).to eq(scenario.handoff_key)
      expect(attrs['agentName']).to eq('Andalusiya Premium Reception Scenario')
    end

    it 'auto-attaches the only listed sendable Captain document when the final response omitted artifact_ids' do
      conversation.messages.incoming.last.update!(content: 'вышли мне документ')
      document = create_sendable_document(name: 'КП MACRO', filename: 'macro.pdf')

      allow(agent_runner_service).to receive(:generate_response).and_return(
        {
          'response' => 'Да, отправляю документ.',
          'artifact_ids' => [],
          'captain_trace' => list_documents_trace(document)
        }
      )

      described_class.perform_now(conversation, assistant)

      public_message = conversation.reload.messages.outgoing.where(private: false).last
      expect(public_message.content).to eq('Да, отправляю документ.')
      expect(public_message.attachments.size).to eq(1)
      expect(public_message.attachments.first.file.filename.to_s).to eq('macro.pdf')
    end

    it 'does not auto-attach a listed document when document delivery was not requested' do
      conversation.messages.incoming.last.update!(content: 'что внутри документа?')
      document = create_sendable_document(name: 'КП MACRO', filename: 'macro.pdf')

      allow(agent_runner_service).to receive(:generate_response).and_return(
        {
          'response' => 'В документе описано коммерческое предложение.',
          'captain_trace' => list_documents_trace(document)
        }
      )

      described_class.perform_now(conversation, assistant)

      public_message = conversation.reload.messages.outgoing.where(private: false).last
      expect(public_message.content).to eq('В документе описано коммерческое предложение.')
      expect(public_message.attachments).to be_empty
    end

    it 'does not auto-attach when several sendable documents were listed and the model omitted artifact_ids' do
      conversation.messages.incoming.last.update!(content: 'вышли мне документ')
      first_document = create_sendable_document(name: 'First', filename: 'first.pdf')
      second_document = create_sendable_document(name: 'Second', filename: 'second.pdf')

      allow(agent_runner_service).to receive(:generate_response).and_return(
        {
          'response' => 'Уточните, какой документ отправить.',
          'captain_trace' => list_documents_trace(first_document, second_document)
        }
      )

      described_class.perform_now(conversation, assistant)

      public_message = conversation.reload.messages.outgoing.where(private: false).last
      expect(public_message.content).to eq('Уточните, какой документ отправить.')
      expect(public_message.attachments).to be_empty
    end

    it 'splits several response attachments into sequential WhatsApp messages' do
      whatsapp_channel = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false)
      whatsapp_inbox = whatsapp_channel.inbox
      create(:captain_inbox, captain_assistant: assistant, inbox: whatsapp_inbox)
      whatsapp_conversation = create(:conversation, inbox: whatsapp_inbox, account: account, status: :pending)
      create(:message, conversation: whatsapp_conversation, content: 'вышли файлы', message_type: :incoming)
      whatsapp_conversation.update!(status: :pending)

      first_document = create_sendable_document(name: 'First', filename: 'first.pdf')
      second_document = create_sendable_document(name: 'Second', filename: 'second.pdf')

      allow(agent_runner_service).to receive(:generate_response).and_return(
        {
          'response' => 'Отправляю файлы.',
          'artifact_ids' => [document_artifact_payload(first_document), document_artifact_payload(second_document)]
        }
      )

      described_class.perform_now(whatsapp_conversation, assistant)

      public_messages = whatsapp_conversation.reload.messages.outgoing.where(private: false).last(2)
      expect(public_messages.map(&:content)).to eq(['Отправляю файлы.', nil])
      expect(public_messages.map { |message| message.attachments.size }).to eq([1, 1])
      expect(public_messages.map { |message| message.attachments.first.file.filename.to_s }).to eq(%w[first.pdf second.pdf])
    end

    it 'sends the text response without attachment when an artifact id expired' do
      allow(agent_runner_service).to receive(:generate_response).and_return(
        {
          'response' => 'Here is the apartment photo.',
          'artifact_ids' => ['expired-artifact-id']
        }
      )
      expect(ChatwootExceptionTracker).not_to receive(:new)

      described_class.perform_now(conversation, assistant)

      public_message = conversation.reload.messages.outgoing.where(private: false).last
      expect(public_message.content).to eq('Here is the apartment photo.')
      expect(public_message.attachments).to be_empty
      expect(conversation.status).to eq('pending')
    end

    it 'creates a fallback text response when an artifact-only response cannot be materialized' do
      allow(agent_runner_service).to receive(:generate_response).and_return(
        {
          'response' => '',
          'artifact_ids' => ['expired-artifact-id']
        }
      )
      expect(ChatwootExceptionTracker).not_to receive(:new)

      described_class.perform_now(conversation, assistant)

      public_message = conversation.reload.messages.outgoing.where(private: false).last
      expect(public_message.content).to eq('The requested file is no longer available. Please ask me to fetch it again.')
      expect(public_message.attachments).to be_empty
      expect(conversation.status).to eq('pending')
    end

    it 'builds tool execution trace from runner callbacks' do
      job = described_class.new
      callbacks, tool_trace_steps = job.send(:build_tool_trace_callbacks)

      callbacks[:on_tool_start].call('search_documentation', { query: 'pricing', api_token: 'x' }, nil)
      callbacks[:on_tool_progress].call('search_documentation', { phase: 'searching' }, nil)
      callbacks[:on_tool_complete].call('search_documentation', Captain::ToolResult.success(message: 'Found 2 docs', data: { ids: [1, 2] }), nil)

      response = { 'response' => 'Hey, welcome to Captain V2' }
      job.instance_variable_set(:@response, response)
      job.send(:attach_tool_trace_to_response!, tool_trace_steps)

      expect(response['captain_trace']).to eq(
        Captain::ToolTraceBuilder.payload([
                                            Captain::ToolTraceBuilder.step(
                                              tool_name: 'search_documentation',
                                              event: 'start',
                                              sequence: 1,
                                              input: { query: 'pricing', api_token: 'x' }
                                            ),
                                            Captain::ToolTraceBuilder.step(
                                              tool_name: 'search_documentation',
                                              event: 'progress',
                                              sequence: 2,
                                              output: { phase: 'searching' }
                                            ),
                                            Captain::ToolTraceBuilder.step(
                                              tool_name: 'search_documentation',
                                              event: 'finish',
                                              sequence: 3,
                                              output: { success: true, message: 'Found 2 docs', data: { ids: [1, 2] } }
                                            )
                                          ])
      )
    end

    it 'stores native and structured reasoning separately in captain trace when no tools ran' do
      job = described_class.new
      response = {
        'response' => 'The deal was already up to date.',
        'reasoning' => 'Native model reasoning.',
        'native_reasoning' => { 'text' => 'Native model reasoning.', 'source' => 'openrouter' },
        'structured_reasoning' => 'Checked the current CRM context and no tool call was required.'
      }
      job.instance_variable_set(:@response, response)

      job.send(:attach_tool_trace_to_response!, [])

      expect(response['captain_trace']).to eq(
        'version' => Captain::ToolTraceBuilder::VERSION,
        'native_reasoning' => { 'text' => 'Native model reasoning.', 'source' => 'openrouter' },
        'structured_reasoning' => 'Checked the current CRM context and no tool call was required.'
      )
    end

    it 'does not duplicate a public handoff message when another run already applied the handoff' do
      save_account_handoff_message(text: 'Connecting you to a human agent.')
      allow(agent_runner_service).to receive(:generate_response) do
        conversation.bot_handoff!
        { 'response' => '', 'handoff_tool_called' => true }
      end

      described_class.perform_now(conversation, assistant)

      conversation.reload
      expect(conversation.status).to eq('open')
      expect(conversation.messages.outgoing.where(private: false)).to be_empty
      expect(conversation.waiting_since).to be_present
    end

    it 'continues with a public response when a strict handoff lacks backend authorization' do
      assistant.update!(config: assistant.config.merge('handoff_requires_explicit_consent' => true))
      original_status = conversation.status
      allow(agent_runner_service).to receive(:generate_response).and_return(
        {
          'response' => 'Продолжу помогать здесь.',
          'handoff_tool_called' => true
        }
      )

      expect(conversation).not_to receive(:bot_handoff!)
      public_message = change { conversation.messages.outgoing.where(private: false).count }.by(1)
      private_message = change { conversation.messages.outgoing.where(private: true).count }.by(0)
      expect { described_class.perform_now(conversation, assistant) }.to public_message.and(private_message)

      expect(conversation.reload.captain_handoff_applied_at).to be_nil
      expect(conversation.status).to eq(original_status)
      expect(conversation.messages.outgoing.where(private: false).last.content).to eq('Продолжу помогать здесь.')
    end

    it 'applies an authorized strict handoff with one public message and one private note' do
      assistant.update!(config: assistant.config.merge('handoff_requires_explicit_consent' => true))
      save_account_handoff_message(mode: 'generated')
      stub_notice_model('Сотрудник продолжит диалог с вами.')
      allow(agent_runner_service).to receive(:generate_response).and_return(
        {
          'response' => 'conversation_handoff',
          'handoff_tool_called' => true,
          'handoff_authorized' => true,
          'handoff_reason' => 'Customer explicitly requested human assistance.',
          'handoff_message' => 'Передаю сотруднику.',
          'captain_request_id' => 'synthetic-request'
        }
      )

      expect(conversation).to receive(:bot_handoff!).once.and_call_original
      allow(Llm::EventBus).to receive(:publish).and_call_original
      expect(Llm::EventBus).to receive(:publish).with(
        'captain.agent.staff_handoff',
        hash_including(request_id: 'synthetic-request', conversation_id: conversation.id, run_source: 'live')
      ).and_call_original
      public_message = change { conversation.messages.outgoing.where(private: false).count }.by(1)
      private_note = change { conversation.messages.outgoing.where(private: true).count }.by(1)
      expect { described_class.perform_now(conversation, assistant) }.to public_message.and(private_note)

      expect(conversation.reload.captain_handoff_applied_at).to be_present
      # The text comes from the notice model, never from the agent's own handoff_message.
      expect(conversation.messages.outgoing.where(private: false).last.content).to eq('Сотрудник продолжит диалог с вами.')
    end

    context 'without phrase-based emergency handoff' do
      before do
        assistant.update!(config: assistant.config.merge('handoff_requires_explicit_consent' => true))
        save_account_handoff_message(mode: 'generated')
      end

      it 'does not synthesize a handoff for a symptom phrase without a tool call' do
        incoming = conversation.messages.incoming.last
        incoming.update!(content: 'У меня сильные боли в груди. Помогите.')
        safety_response = 'Срочно вызывайте 103 или 112. Не откладывайте звонок.'
        expect(agent_runner_service).to receive(:generate_response).once.and_return(
          {
            'response' => safety_response,
            'handoff_tool_called' => false,
            'handoff_status_reason' => 'provider-controlled-status-reason'
          }
        )
        public_message = change { conversation.messages.outgoing.where(private: false).count }.by(1)
        private_note = change { conversation.messages.outgoing.where(private: true).count }.by(0)
        expect do
          described_class.perform_now(conversation, assistant, expected_last_message_id: incoming.id)
        end.to public_message.and(private_note)

        conversation.reload
        expect(conversation.status).to eq('pending')
        expect(conversation.captain_handoff_applied_at).to be_nil
        expect(conversation.messages.outgoing.where(private: false).last.content).to eq(safety_response)
      end

      it 'does not inject an emergency template when the tool was not called' do
        account.update!(locale: 'ru')
        incoming = conversation.messages.incoming.last
        incoming.update!(content: 'У меня сильные боли в груди. Помогите.')
        allow(agent_runner_service).to receive(:generate_response).and_return(
          {
            'response' => 'Пожалуйста, ожидайте ответа.',
            'handoff_tool_called' => false
          }
        )

        described_class.perform_now(conversation, assistant, expected_last_message_id: incoming.id)

        expect(conversation.reload.status).to eq('pending')
        expect(conversation.messages.outgoing.where(private: false).last.content).to eq('Пожалуйста, ожидайте ответа.')
      end

      [
        'У меня нет сильных болей в груди.',
        'У меня не сильные боли в груди.',
        'Сильных болей в груди нет.'
      ].each do |content|
        it "does not hand off a negated chest-pain statement: #{content}" do
          incoming = conversation.messages.incoming.last
          incoming.update!(content: content)
          allow(agent_runner_service).to receive(:generate_response).and_return(
            {
              'response' => 'Продолжу помогать здесь.',
              'handoff_tool_called' => false
            }
          )

          expect do
            described_class.perform_now(conversation, assistant, expected_last_message_id: incoming.id)
          end.not_to(change { conversation.messages.outgoing.where(private: true).count })

          expect(conversation.reload.status).to eq('pending')
          expect(conversation.captain_handoff_applied_at).to be_nil
          expect(conversation.messages.outgoing.where(private: false).last.content).to eq('Продолжу помогать здесь.')
        end
      end

      it 'does not synthesize a handoff for a non-emergency direct request when the tool was not called' do
        incoming = conversation.messages.incoming.last
        incoming.update!(content: 'Соедините меня с сотрудником.')
        allow(agent_runner_service).to receive(:generate_response).and_return(
          {
            'response' => 'Уточню ваш вопрос здесь.',
            'handoff_tool_called' => false
          }
        )

        described_class.perform_now(conversation, assistant, expected_last_message_id: incoming.id)

        expect(conversation.reload.status).to eq('pending')
        expect(conversation.captain_handoff_applied_at).to be_nil
        expect(conversation.messages.outgoing.where(private: true)).to be_empty
      end
    end

    it 'keeps the no-tool emergency response on the legacy path when explicit consent gating is disabled' do
      incoming = conversation.messages.incoming.last
      incoming.update!(content: 'У меня сильные боли в груди. Помогите.')
      allow(agent_runner_service).to receive(:generate_response).and_return(
        {
          'response' => 'Срочно вызывайте 103 или 112.',
          'handoff_tool_called' => false
        }
      )

      described_class.perform_now(conversation, assistant, expected_last_message_id: incoming.id)

      expect(conversation.reload.status).to eq('pending')
      expect(conversation.captain_handoff_applied_at).to be_nil
      expect(conversation.messages.outgoing.where(private: true)).to be_empty
    end

    it 'hands a semantic output error to people as a failed turn' do
      allow(agent_runner_service).to receive(:generate_response).and_return(
        {
          'response' => Captain::Assistant::AgentRunnerService::PROVIDER_ERROR_RESPONSE,
          'error_class' => 'SemanticOutputError'
        }
      )

      expect { described_class.perform_now(conversation, assistant) }
        .to change { conversation.messages.outgoing.where(private: true).count }.by(1)
      expect(conversation.reload.status).to eq('open')
      expect(conversation.captain_handoff_applied_at).to be_present
      expect(conversation.messages.outgoing.where(private: false)).to be_empty
    end

    context 'when a configured custom check stops the reply' do
      let(:approved_message) { 'Your request has been transferred to staff.' }
      let(:saved_rule) do
        {
          'id' => 'current_request', 'name' => 'Current request', 'direction' => 'input',
          'instruction' => 'Hand off a current request that needs staff.', 'action' => 'handoff',
          'enabled' => true, 'message' => approved_message
        }
      end
      let(:guardrail_response) do
        {
          'response' => Captain::Assistant::AgentRunnerService::PROVIDER_ERROR_RESPONSE,
          Captain::Assistant::AgentRunnerService::PROVIDER_ERROR_AUTHORIZED_KEY => true,
          'agent_id' => assistant.id,
          'custom_guardrail' => {
            'direction' => 'input', 'rule_id' => saved_rule['id'], 'action' => 'handoff',
            'approved_message' => 'Text supplied by the response payload.'
          }
        }
      end

      before do
        save_custom_handoff_rules(saved_rule)
        allow(agent_runner_service).to receive(:generate_response).and_return(guardrail_response)
      end

      # Custom checks and the ordinary handoff message live in the one account-level
      # settings object (API format: inbound/outbound directions).
      def save_custom_handoff_rules(*rules)
        api_rules = rules.map do |rule|
          rule.merge('direction' => Captain::AccountSettings::RULE_DIRECTION_TO_API.fetch(rule['direction']),
                     'action' => Captain::AccountSettings::RULE_ACTION_TO_API.fetch(rule['action']))
        end
        Captain::AccountSettings.new(account).update!(
          'handoff' => { 'handoff_message' => { 'enabled' => false } },
          'safety' => { 'custom_rules' => api_rules }
        )
      end

      def expect_no_custom_guardrail_handoff
        expect(conversation.reload.captain_handoff_applied_at).to be_nil
        expect(conversation.messages.where(private: true, content: described_class::CUSTOM_GUARDRAIL_HANDOFF_NOTE)).to be_empty
        expect(conversation.messages.outgoing.where(sender: assistant)).to be_empty
      end

      # The handoff tool is always available to external agents (owner decision);
      # only the ordinary handoff message can be switched off.
      it 'sends the saved static message once even when the ordinary handoff message is disabled' do
        expect(assistant.handoff_message_enabled?).to be(false)

        2.times { described_class.perform_now(conversation, assistant) }

        expect(conversation.reload.status).to eq('open')
        expect(conversation.captain_handoff_applied_at).to be_present
        expect(conversation.waiting_since).to be_present
        expect(conversation.messages.outgoing.where(private: false).pluck(:content)).to eq([approved_message])
        expect(conversation.messages.where(private: true).pluck(:content)).to eq([described_class::CUSTOM_GUARDRAIL_HANDOFF_NOTE])
        expect(conversation.status_transitions.last).to have_attributes(source: 'system', actor: assistant)
        expect(agent_runner_service).to have_received(:generate_response).once
      end

      it 'loads the latest saved message instead of trusting text in the response payload' do
        updated_message = 'Staff will handle the request recorded in this conversation.'
        allow(agent_runner_service).to receive(:generate_response) do
          save_custom_handoff_rules(saved_rule.merge('message' => updated_message))
          guardrail_response
        end

        described_class.perform_now(conversation, assistant)

        expect(conversation.reload.messages.outgoing.where(private: false).pluck(:content)).to eq([updated_message])
        expect(conversation.messages.where(content: guardrail_response.dig('custom_guardrail', 'approved_message'))).to be_empty
      end

      it 'does not send payload text when the saved rule has no message' do
        save_custom_handoff_rules(saved_rule.except('message'))

        described_class.perform_now(conversation, assistant)

        expect(conversation.reload.status).to eq('open')
        expect(conversation.messages.outgoing.where(private: false)).to be_empty
        expect(conversation.messages.where(private: true).pluck(:content)).to eq([described_class::CUSTOM_GUARDRAIL_HANDOFF_NOTE])
      end

      %w[disabled deleted direction_changed].each do |change|
        it "does not send the matched rule message when the saved rule is #{change.tr('_', ' ')}" do
          rules = case change
                  when 'disabled' then [saved_rule.merge('enabled' => false)]
                  when 'deleted' then []
                  when 'direction_changed' then [saved_rule.merge('direction' => 'output')]
                  end
          save_custom_handoff_rules(*rules)

          described_class.perform_now(conversation, assistant)

          expect(conversation.reload.status).to eq('open')
          expect(conversation.messages.outgoing.where(private: false)).to be_empty
          expect(conversation.messages.where(private: true).pluck(:content)).to eq([described_class::CUSTOM_GUARDRAIL_HANDOFF_NOTE])
        end
      end

      it 'uses the routed actor and saved profile for the handoff message' do
        routed_assistant = create(:captain_assistant, account: account)
        assistant.update!(handoff_agent_ids: [routed_assistant.id])
        routed_message = 'The specialist has transferred your request to staff.'
        save_custom_handoff_rules(saved_rule.merge('message' => routed_message))
        Captain::Conversation::AgentSession.new(entry: assistant, conversation: conversation).update_routing(actor_id: routed_assistant.id)
        allow(agent_runner_service).to receive(:generate_response).and_return(guardrail_response.merge('agent_id' => routed_assistant.id))

        described_class.perform_now(conversation, assistant)

        public_message = conversation.reload.messages.outgoing.where(private: false).sole
        expect(public_message).to have_attributes(content: routed_message, sender: routed_assistant)
        expect(conversation.status_transitions.last).to have_attributes(source: 'system', actor: routed_assistant)
        expect(conversation.messages.where(private: true).sole.sender).to eq(routed_assistant)
      end

      it 'blocks a secret-shaped string in the saved static message' do
        fake_secret_message = 'api_key=FAKE_CUSTOM_GUARDRAIL_SECRET_NOT_REAL_123456'
        save_custom_handoff_rules(saved_rule.merge('message' => fake_secret_message))

        described_class.perform_now(conversation, assistant)

        expect(conversation.reload.status).to eq('open')
        expect(conversation.messages.outgoing.where(private: false)).to be_empty
        expect(conversation.messages.where(content: fake_secret_message)).to be_empty
        expect(conversation.messages.where(private: true).pluck(:content)).to eq([described_class::CUSTOM_GUARDRAIL_HANDOFF_NOTE])
      end

      it 'sends neither the message nor the handoff if a newer customer message wins the locked fence' do
        job = described_class.new
        allow(job).to receive(:handoff_failed_turn).and_wrap_original do |method|
          create(:message, conversation: conversation, content: 'A newer request', message_type: :incoming)
          method.call
        end

        job.perform(conversation, assistant)

        expect(conversation.reload.status).to eq('pending')
        expect_no_custom_guardrail_handoff
      end

      it 'sends neither the message nor the handoff if the status epoch changes before the locked handoff' do
        job = described_class.new
        allow(job).to receive(:handoff_failed_turn).and_wrap_original do |method|
          Conversations::StatusTransitionService.new(conversation: conversation, params: { status: 'open' }, source: 'system').perform
          Conversations::StatusTransitionService.new(conversation: conversation, params: { status: 'pending' }, source: 'system').perform
          method.call
        end

        job.perform(conversation, assistant)

        expect(conversation.reload.status).to eq('pending')
        expect_no_custom_guardrail_handoff
      end
    end

    it 'hands a provider error to people as a system handoff, not as an AI tool call' do
      allow(agent_runner_service).to receive(:generate_response).and_return(
        {
          'response' => Captain::Assistant::AgentRunnerService::PROVIDER_ERROR_RESPONSE,
          Captain::Assistant::AgentRunnerService::PROVIDER_ERROR_AUTHORIZED_KEY => true,
          'error_class' => 'RubyLLM::RateLimitError'
        }
      )

      described_class.perform_now(conversation, assistant)

      expect(conversation.reload.status).to eq('open')
      expect(conversation.status_transitions.last).to have_attributes(
        from_status: 'pending', to_status: 'open', source: 'system', reason: 'Reason is being classified', actor: assistant
      )
      expect(conversation.status_transitions.last.metadata['outcome_reason_explanation']).to eq(described_class::FAILED_TURN_HANDOFF_NOTE)
      expect(conversation.messages.outgoing.where(private: false)).to be_empty
    end

    it 'hands a turn blocked by moderation to people with a moderation note' do
      allow(agent_runner_service).to receive(:generate_response).and_return(
        {
          'response' => 'conversation_handoff',
          'reasoning' => 'Agent input blocked by moderation policy',
          Captain::Assistant::AgentRunnerService::MODERATION_BLOCKED_KEY => true
        }
      )

      described_class.perform_now(conversation, assistant)

      expect(conversation.reload.status).to eq('open')
      expect(conversation.status_transitions.last).to have_attributes(source: 'system', actor: assistant)
      expect(conversation.messages.where(private: true).pluck(:content)).to eq([described_class::MODERATION_HANDOFF_NOTE])
      expect(conversation.messages.outgoing.where(private: false)).to be_empty
    end

    it 'keeps an unmarked conversation_handoff value without the handoff tool cancelled' do
      allow(agent_runner_service).to receive(:generate_response).and_return(
        { 'response' => 'conversation_handoff', 'reasoning' => 'Customer wants a person', 'moderation_blocked' => 'true' }
      )

      expect { described_class.perform_now(conversation, assistant) }.not_to(change { conversation.messages.count })

      expect(conversation.reload.status).to eq('pending')
      expect(conversation.captain_handoff_applied_at).to be_nil
    end

    it 'hands the model conversation_handoff value without the handoff tool to people as a failed turn' do
      # AgentRunnerService.new is stubbed in this group; build a real runner to process the model output.
      runner = Captain::Assistant::AgentRunnerService.allocate
      runner.send(:initialize, assistant: assistant, conversation: conversation)
      allow(Llm::EventBus).to receive(:publish)
      model_result = Struct.new(:output, :context, :error).new(
        { 'response' => 'conversation_handoff', 'reasoning' => 'Customer wants a person', 'handoff_reason' => 'asked for admin' },
        { current_agent: 'assistant' },
        nil
      )
      allow(agent_runner_service).to receive(:generate_response).and_return(runner.send(:process_agent_result, model_result))

      described_class.perform_now(conversation, assistant)

      expect(conversation.reload.status).to eq('open')
      expect(conversation.messages.where(private: true).pluck(:content)).to eq([described_class::FAILED_TURN_HANDOFF_NOTE])
      expect(conversation.messages.where(content: 'asked for admin')).to be_empty
      expect(conversation.messages.outgoing.where(private: false)).to be_empty
    end

    it 'does not consume usage when a handoff loses the control fence' do
      allow(Llm::EventBus).to receive(:publish)
      allow(agent_runner_service).to receive(:generate_response).and_return(
        {
          'response' => 'conversation_handoff',
          'handoff_tool_called' => true,
          'handoff_authorized' => true,
          'usage' => { 'total_tokens' => 42 }
        }
      )
      job = described_class.new
      control_changed = false
      allow(job).to receive(:handoff_requested?).and_wrap_original do |method|
        unless control_changed
          conversation.activate_captain_human_control!(source: 'test_handoff_race')
          control_changed = true
        end
        method.call
      end
      expect do
        job.perform(conversation, assistant)
      end.not_to(change { account.reload.usage_limits[:captain][:responses][:consumed] })

      expect(conversation.reload.captain_handoff_applied_at).to be_nil
      expect(conversation.messages.outgoing.where(sender: assistant)).to be_empty
    end

    it 'does not reopen a conversation resolved after response processing starts' do
      allow(Llm::EventBus).to receive(:publish)
      allow(agent_runner_service).to receive(:generate_response).and_return(
        {
          'response' => 'conversation_handoff',
          'handoff_tool_called' => true,
          'handoff_authorized' => true,
          'usage' => { 'total_tokens' => 42 }
        }
      )
      job = described_class.new
      status_changed = false
      allow(job).to receive(:handoff_requested?).and_wrap_original do |method|
        unless status_changed
          conversation.update!(status: :resolved)
          status_changed = true
        end
        method.call
      end

      expect do
        job.perform(conversation, assistant)
      end.not_to(change { account.reload.usage_limits[:captain][:responses][:consumed] })

      expect(conversation.reload).to be_resolved
      expect(conversation.captain_handoff_applied_at).to be_nil
      expect(conversation.messages.outgoing.where(sender: assistant)).to be_empty
      expect(Llm::EventBus).to have_received(:publish).with(
        'captain.run.fenced',
        hash_including(conversation_id: conversation.id, reason: 'status_changed', stage: 'response_handoff')
      )
    end

    it 'does not hand off after a status epoch changes between the response fence and locked handoff' do
      allow(agent_runner_service).to receive(:generate_response).and_return(
        { 'response' => 'conversation_handoff', 'handoff_tool_called' => true, 'handoff_authorized' => true }
      )
      job = described_class.new
      allow(job).to receive(:bot_handoff_with_activity_reason).and_wrap_original do |method, *args, **kwargs, &block|
        Conversations::StatusTransitionService.new(conversation: conversation, params: { status: 'open' }, source: 'system').perform
        Conversations::StatusTransitionService.new(conversation: conversation, params: { status: 'pending' }, source: 'system').perform
        method.call(*args, **kwargs, &block)
      end

      job.perform(conversation, assistant)

      expect(conversation.reload.status).to eq('pending')
      expect(conversation.captain_handoff_applied_at).to be_nil
      expect(conversation.messages.outgoing.where(sender: assistant)).to be_empty
    end

    context 'when a council reply promises an unresolved part to staff' do
      let(:council_response) do
        { 'response' => 'Приём стоит 5000 тенге, а на остальное ответит сотрудник.',
          'council_handoff' => { 'reason' => 'council_unresolved', 'parts' => ['Результаты анализов'] } }
      end

      before { allow(agent_runner_service).to receive(:generate_response).and_return(council_response) }

      it 'delivers the reply first, then hands the conversation to staff with a private note and no second public message' do
        expect { described_class.perform_now(conversation, assistant) }
          .to change { conversation.messages.outgoing.where(private: false).count }.by(1)

        conversation.reload
        reply = conversation.messages.outgoing.where(private: false).sole
        note = conversation.messages.outgoing.where(private: true).last
        expect(reply.content).to eq(council_response['response'])
        expect(note.content).to include('Результаты анализов')
        expect(note.id).to be > reply.id
        expect(conversation.status).to eq('open')
      end

      it 'records the staff handoff like any other handoff' do
        allow(Llm::EventBus).to receive(:publish)

        described_class.perform_now(conversation, assistant)

        expect(Llm::EventBus).to have_received(:publish).with('captain.agent.staff_handoff', hash_including(conversation_id: conversation.id))
      end

      it 'keeps the delivered reply and sends no failed-turn message when the handoff itself fails' do
        allow_any_instance_of(described_class).to receive(:process_action).and_raise(ActiveRecord::Deadlocked)
        allow(ChatwootExceptionTracker).to receive(:new).and_call_original

        expect { described_class.perform_now(conversation, assistant) }.not_to raise_error

        expect(ChatwootExceptionTracker).to have_received(:new).with(an_instance_of(ActiveRecord::Deadlocked), account: account)
        expect(conversation.reload.messages.outgoing.where(private: false).pluck(:content)).to eq([council_response['response']])
        expect(conversation.status).to eq('pending')
      end

      it 'keeps the conversation with the agent when the agent cannot hand off to staff' do
        allow_any_instance_of(Captain::Assistant).to receive(:handoff_enabled?).and_return(false)

        described_class.perform_now(conversation, assistant)

        expect(conversation.reload.messages.outgoing.where(private: false).pluck(:content)).to eq([council_response['response']])
        expect(conversation.messages.outgoing.where(private: true)).to be_empty
        expect(conversation.status).to eq('pending')
      end

      it 'does not hand off when a human replied during generation and the reply was not delivered' do
        agent = create(:user, account: account, role: :agent)
        expected_generation = conversation.captain_control_generation
        allow(agent_runner_service).to receive(:generate_response) do
          create(:message, conversation: conversation, message_type: :outgoing, sender: agent, account: account, inbox: inbox)
          council_response
        end

        described_class.perform_now(conversation, assistant, expected_control_generation: expected_generation)

        expect(conversation.messages.outgoing.where(sender: assistant)).to be_empty
        expect(conversation.reload.status).to eq('open')
      end
    end

    context 'when a tool of the agent failed technically and the run ended without a reply' do
      let(:failure) do
        { 'tool' => 'create_appointment', 'kind' => 'technical', 'stage' => 'tool_execution', 'reason' => 'provider_unavailable',
          'completed' => ['cancel_appointment'] }
      end
      let(:failed_turn) do
        { 'response' => Captain::Assistant::AgentRunnerService::PROVIDER_ERROR_RESPONSE,
          Captain::Assistant::AgentRunnerService::PROVIDER_ERROR_AUTHORIZED_KEY => true,
          'error_class' => Captain::Assistant::AgentRunnerService::TECHNICAL_FAILURE_ERROR_CLASS, 'technical_failure' => failure }
      end
      let(:note) do
        'Automatic reply was stopped by a technical error (create_appointment / tool_execution / provider_unavailable). ' \
          'Handoff to human agent was triggered. Completed before the error: cancel_appointment.'
      end

      before { allow(agent_runner_service).to receive(:generate_response).and_return(failed_turn) }

      it 'hands the conversation to staff at once with a note that names what failed, and writes nothing to the customer' do
        described_class.perform_now(conversation, assistant)

        expect(conversation.reload.status).to eq('open')
        expect(conversation.status_transitions.last).to have_attributes(source: 'system', actor: assistant, from_status: 'pending', to_status: 'open')
        expect(conversation.messages.where(private: true).pluck(:content)).to eq([note])
        expect(conversation.messages.outgoing.where(private: false)).to be_empty
      end

      it 'names the tool and the codes only: no argument, no message, no patient' do
        failure['error'] = 'Patient Айгуль +77010000000 rejected'
        failure['arguments'] = { 'phone' => '+77010000000' }

        described_class.perform_now(conversation, assistant)

        expect(conversation.reload.messages.where(private: true).pluck(:content).join).not_to include('Айгуль', '7701')
      end

      it 'sends the handoff notice of the workspace through the notice service, as for any handoff of the system' do
        save_account_handoff_message(text: 'Сотрудник продолжит диалог с вами.')

        described_class.perform_now(conversation, assistant)

        expect(conversation.reload.messages.outgoing.where(private: false).pluck(:content)).to eq(['Сотрудник продолжит диалог с вами.'])
        expect(conversation.status).to eq('open')
      end

      it 'hands over although the agent has no handoff tool: it is the system that does it' do
        allow_any_instance_of(Captain::Assistant).to receive(:handoff_enabled?).and_return(false)

        described_class.perform_now(conversation, assistant)

        expect(conversation.reload.status).to eq('open')
        expect(conversation.messages.where(private: true).pluck(:content)).to eq([note])
      end

      it 'says nothing about the failure to the customer, whatever the notice is' do
        save_account_handoff_message(text: 'Сотрудник продолжит диалог с вами.')

        described_class.perform_now(conversation, assistant)

        public_text = conversation.reload.messages.outgoing.where(private: false).pluck(:content).join
        expect(public_text).not_to include('create_appointment', 'ошибк', 'не получилось', 'Не удалось')
      end

      it 'records the staff handoff like any other handoff' do
        allow(Llm::EventBus).to receive(:publish)

        described_class.perform_now(conversation, assistant)

        expect(Llm::EventBus).to have_received(:publish).with('captain.agent.staff_handoff', hash_including(conversation_id: conversation.id))
      end
    end

    context 'when a council reply left out a part whose tool failed technically' do
      let(:council_response) do
        { 'response' => 'Приём стоит 5000 тенге.',
          'council_handoff' => { 'reason' => 'council_technical_failure', 'parts' => [], 'technical' => true,
                                 'failures' => [{ 'tool' => 'create_appointment', 'stage' => 'tool_execution', 'reason' => 'provider_unavailable' }] } }
      end
      let(:technical_note) do
        I18n.t('captain.coordination.technical_failure_note', details: 'create_appointment / tool_execution / provider_unavailable',
                                                              locale: account.locale)
      end

      before { allow(agent_runner_service).to receive(:generate_response).and_return(council_response) }

      it 'delivers the reply first, then hands the conversation to staff with a note that names what failed' do
        described_class.perform_now(conversation, assistant)

        conversation.reload
        reply = conversation.messages.outgoing.where(private: false).sole
        note = conversation.messages.outgoing.where(private: true).last
        expect(reply.content).to eq('Приём стоит 5000 тенге.')
        expect(note.content).to eq(technical_note)
        expect(note.id).to be > reply.id
        expect(conversation.status).to eq('open')
      end

      it 'follows the reply with the handoff notice of the workspace' do
        save_account_handoff_message(text: 'Сотрудник продолжит диалог с вами.')

        described_class.perform_now(conversation, assistant)

        public_messages = conversation.reload.messages.outgoing.where(private: false).order(:id)
        expect(public_messages.pluck(:content)).to eq(['Приём стоит 5000 тенге.', 'Сотрудник продолжит диалог с вами.'])
        expect(conversation.status).to eq('open')
      end

      it 'sends no notice when the workspace has none' do
        described_class.perform_now(conversation, assistant)

        expect(conversation.reload.messages.outgoing.where(private: false).pluck(:content)).to eq(['Приём стоит 5000 тенге.'])
      end

      it 'hands over although the agent cannot hand off to staff: the failure is the system\'s, not the agent\'s request' do
        allow_any_instance_of(Captain::Assistant).to receive(:handoff_enabled?).and_return(false)

        described_class.perform_now(conversation, assistant)

        expect(conversation.reload.status).to eq('open')
        expect(conversation.messages.where(private: true).pluck(:content)).to eq([technical_note])
      end

      it 'does not say a word about the failure in the reply' do
        described_class.perform_now(conversation, assistant)

        expect(conversation.reload.messages.outgoing.where(private: false).pluck(:content).join).not_to include('create_appointment')
      end
    end

    context 'when the agent that planned a council asked for staff next to its plan' do
      let(:reason) { 'Запрос результата: Жанна Оспанова, ТТГ, сдан 9 октября; проверить готовность результата' }
      let(:council_response) do
        { 'response' => 'Повторный приём стоит 8000 тенге.',
          'council_handoff' => { 'reason' => 'council_unresolved', 'parts' => [], 'staff_reason' => reason } }
      end

      before { allow(agent_runner_service).to receive(:generate_response).and_return(council_response) }

      it 'delivers the answers of the other parts, then hands the conversation to staff with a private note that gives the reason' do
        described_class.perform_now(conversation, assistant)

        conversation.reload
        expect(conversation.messages.outgoing.where(private: false).pluck(:content)).to eq(['Повторный приём стоит 8000 тенге.'])
        expect(conversation.messages.outgoing.where(private: true).last.content).to eq(
          I18n.t('captain.coordination.unresolved_handoff', parts: reason, locale: account.locale)
        )
        expect(conversation.status).to eq('open')
      end

      it 'names the unanswered parts rather than the reason when the council has some' do
        council_response['council_handoff']['parts'] = ['Результаты анализов']

        described_class.perform_now(conversation, assistant)

        expect(conversation.reload.messages.outgoing.where(private: true).last.content).to eq(
          I18n.t('captain.coordination.unresolved_handoff', parts: 'Результаты анализов', locale: account.locale)
        )
      end
    end

    context 'when no part of a council has a text for the customer' do
      let(:unreported_note) do
        I18n.t('captain.coordination.unreported_action_note', parts: 'Запись к терапевту', locale: account.locale)
      end
      let(:council_response) do
        { 'response' => '', 'response_mode' => 'suppress', 'response_suppressed' => true,
          'council_handoff' => { 'reason' => 'council_unresolved', 'parts' => ['Результаты анализов'] },
          'council_note' => { 'unreported' => ['Запись к терапевту'] } }
      end

      before { allow(agent_runner_service).to receive(:generate_response).and_return(council_response) }

      it 'sends no public message, not even a notice, and hands the conversation to staff in silence with the private notes' do
        save_account_handoff_message(text: 'Сотрудник продолжит диалог с вами.')

        described_class.perform_now(conversation, assistant)

        conversation.reload
        expect(conversation.messages.outgoing.where(private: false)).to be_empty
        notes = conversation.messages.outgoing.where(private: true).pluck(:content)
        expect(notes).to include(a_string_including('Результаты анализов'), unreported_note)
        expect(conversation.status).to eq('open')
      end

      it 'keeps the conversation with the agent when it cannot hand off to staff, and still notes the action' do
        allow_any_instance_of(Captain::Assistant).to receive(:handoff_enabled?).and_return(false)

        described_class.perform_now(conversation, assistant)

        conversation.reload
        expect(conversation.messages.outgoing.where(private: false)).to be_empty
        expect(conversation.messages.outgoing.where(private: true).pluck(:content)).to eq([unreported_note])
        expect(conversation.status).to eq('pending')
      end

      it 'is not a failed turn: nothing is sent and no error is recorded' do
        allow(Llm::EventBus).to receive(:publish)

        described_class.perform_now(conversation, assistant)

        expect(Llm::EventBus).to have_received(:publish).with('captain.response.suppressed', hash_including(conversation_id: conversation.id))
      end
    end

    context 'when a council reply leaves out an action that no text reported and a part that nobody will answer' do
      let(:council_response) do
        { 'response' => 'Приём стоит 5000 тенге.',
          'council_note' => { 'unreported' => ['Запись к терапевту'], 'unanswered' => ['Результаты анализов'] } }
      end

      before { allow(agent_runner_service).to receive(:generate_response).and_return(council_response) }

      it 'delivers the reply, then writes one private note for each, and does not hand the conversation over' do
        described_class.perform_now(conversation, assistant)

        conversation.reload
        expect(conversation.messages.outgoing.where(private: false).pluck(:content)).to eq(['Приём стоит 5000 тенге.'])
        expect(conversation.messages.outgoing.where(private: true).order(:id).pluck(:content)).to eq(
          [I18n.t('captain.coordination.unreported_action_note', parts: 'Запись к терапевту', locale: account.locale),
           I18n.t('captain.coordination.unresolved_handoff', parts: 'Результаты анализов', locale: account.locale)]
        )
        expect(conversation.status).to eq('pending')
      end

      it 'keeps the delivered reply when the note cannot be written' do
        allow_any_instance_of(described_class).to receive(:create_private_note).and_raise(ActiveRecord::StatementInvalid)

        expect { described_class.perform_now(conversation, assistant) }.not_to raise_error

        expect(conversation.reload.messages.outgoing.where(private: false).pluck(:content)).to eq(['Приём стоит 5000 тенге.'])
      end
    end

    # The whole path of a live run, with only the provider faked: the real booking tool fails with an unknown outcome inside the real
    # tool wrapper, the runner service builds the failed turn from what the run left in its context, and this job answers it. The tool
    # leaves the conversation pending and writes nothing (no handoff and no note of its own), so the reply is not dropped by its own
    # fence and the handoff of the failed turn applies, writes its one note and sends the notice.
    context 'when create_appointment of the live run ends with an unknown provider outcome' do
      let(:notice) { 'Сотрудник продолжит диалог с вами.' }
      let(:real_tool) { Captain::Tools::CreateAppointmentTool.new(assistant) }
      let(:booking_tool) do
        real = real_tool
        Class.new(Captain::Runtime::Tool) do
          define_method(:name) { 'create_appointment' }
          define_method(:description) { 'Create an appointment' }
          define_method(:metadata) { { risk_level: 'high', idempotent: false } }
          define_method(:perform) { |tool_context, **| real.perform(tool_context, resource_id: 1, starts_at: Time.current.iso8601) }
        end.new
      end

      def run_live_booking(fence)
        account.enable_features!('scheduling')
        appointment = create(:scheduling_appointment, account: account, contact: conversation.contact, conversation: conversation)
        operations = instance_double(Captain::Tools::Operations::AppointmentOperations,
                                     create_appointment: appointment, already_booked_appointment: nil)
        outcome = instance_double(Captain::Tools::ProviderBookingOutcomeService)
        allow(outcome).to receive(:perform).and_raise(
          Scheduling::Error.new(code: 'MEDELEMENT_BOOKING_UNKNOWN', message: 'Staff verification required', status: :unprocessable_content)
        )
        allow(real_tool).to receive(:operations).and_return(operations)
        allow(Captain::Tools::ProviderBookingOutcomeService).to receive(:new).and_return(outcome)
        run = Captain::Runtime::RunContext.new(
          { current_agent: 'assistant', state: { account_id: account.id, assistant_id: assistant.id, conversation: { id: conversation.id },
                                                 captain_response_fence: fence } }
        )

        expect(Captain::Runtime::ToolWrapper.new(booking_tool, run).call({})).to be_a(RubyLLM::Tool::Halt)
        Struct.new(:output, :context, :error).new(nil, run.context, Captain::Runtime::Runner::TechnicalFailure.new('technical failure'))
      end

      before do
        allow(Captain::Assistant::AgentRunnerService).to receive(:new).and_call_original
        allow_any_instance_of(Captain::Assistant::AgentRunnerService).to receive(:generate_response) do |service, **|
          service.send(:process_agent_result, run_live_booking(service.instance_variable_get(:@response_fence)))
        end
      end

      it 'hands the conversation to staff once, with the notice of the workspace, one note that names the failure and nothing else public' do
        save_account_handoff_message(text: notice)

        described_class.perform_now(conversation, assistant)

        conversation.reload
        expect(conversation.status).to eq('open')
        expect(conversation.messages.outgoing.where(private: false).pluck(:content)).to eq([notice])
        notes = conversation.messages.outgoing.where(private: true).order(:id).pluck(:content)
        expect(notes.size).to eq(1)
        expect(notes.sole).to include('Automatic reply was stopped by a technical error (create_appointment')
        expect(conversation.status_transitions.last).to have_attributes(source: 'system', from_status: 'pending', to_status: 'open')
      end

      it 'says nothing to the customer when the workspace has no notice, and still hands the conversation to staff' do
        described_class.perform_now(conversation, assistant)

        expect(conversation.reload.status).to eq('open')
        expect(conversation.messages.outgoing.where(private: false)).to be_empty
        expect(conversation.messages.outgoing.where(private: true).count).to eq(1)
      end
    end

    # Regression (PR #13417): wrapping create_handoff_message and bot_handoff! in the
    # same transaction defers the message's after_create_commit until commit, at which
    # point it clears waiting_since (bot_response). The handoff path must stay outside
    # the transaction so the callback fires before bot_handoff! sets waiting_since.
    context 'when handoff is requested' do
      let(:agent) { create(:user, account: account, role: :agent) }

      before do
        allow(agent_runner_service).to receive(:generate_response).and_return(
          { 'response' => 'conversation_handoff', 'handoff_tool_called' => true, 'handoff_authorized' => true }
        )
      end

      it 'restores waiting_since after the handoff message callbacks' do
        save_account_handoff_message(text: 'Connecting you to a human agent.')
        conversation.update!(waiting_since: nil)

        expect { described_class.perform_now(conversation, assistant) }
          .to change { conversation.messages.outgoing.where(private: false).count }.by(1)

        conversation.reload
        expect(conversation.status).to eq('open')
        expect(conversation.waiting_since).to be_present
      end

      it 'preserves waiting_since so a human reply consumes it for reply_time tracking' do
        save_account_handoff_message(text: 'Connecting you to a human agent.')
        described_class.perform_now(conversation, assistant)

        conversation.reload
        expect(conversation.waiting_since).to be_present

        create(:message, conversation: conversation, message_type: :outgoing,
                         sender: agent, account: account, inbox: inbox)
        expect(conversation.reload.waiting_since).to be_nil
      end

      it 'keeps captain trace on the configured static handoff message' do
        save_account_handoff_message(text: 'Connecting you to a human agent.')
        trace_payload = Captain::ToolTraceBuilder.payload([
                                                            Captain::ToolTraceBuilder.step(
                                                              tool_name: 'search_documentation',
                                                              event: 'start',
                                                              sequence: 1
                                                            )
                                                          ])
        allow(agent_runner_service).to receive(:generate_response).and_return(
          {
            'response' => 'conversation_handoff',
            'handoff_tool_called' => true,
            'handoff_authorized' => true,
            'captain_trace' => trace_payload
          }
        )

        described_class.perform_now(conversation, assistant)

        expect(conversation.reload.messages.outgoing.last.additional_attributes['captain_trace']).to eq(trace_payload)
      end

      it 'creates a private note but no public notice when handoff message is disabled' do
        save_account_handoff_message(enabled: false)

        public_message = change { conversation.messages.outgoing.where(private: false).count }.by(0)
        private_note = change { conversation.messages.outgoing.where(private: true).count }.by(1)
        expect { described_class.perform_now(conversation, assistant) }.to public_message.and(private_note)

        expect(conversation.reload.status).to eq('open')
        expect(conversation.messages.outgoing.where(private: true).last.content).to eq(
          described_class::DEFAULT_HANDOFF_PRIVATE_NOTE
        )
      end

      it 'sends no public text, and no built-in transfer wording, when the static handoff message is blank' do
        save_account_handoff_message(text: '')
        expect(Llm::Runtime).not_to receive(:chat)

        expect do
          described_class.perform_now(conversation, assistant)
        end.not_to(change { conversation.messages.outgoing.where(private: false).count })

        expect(conversation.reload.status).to eq('open')
      end

      it 'uses the text the notice model wrote when AI handoff message mode is enabled, with the owner instruction' do
        save_account_handoff_message(mode: 'generated', instruction: 'Коротко и вежливо.')
        request = {}
        stub_notice_model
        allow(Llm::Runtime).to receive(:chat).with(hash_including(feature: :customer_notice)) do |**attributes|
          request.merge!(attributes)
          Struct.new(:content).new('Сотрудник продолжит диалог с вами.')
        end
        allow(agent_runner_service).to receive(:generate_response).and_return(
          {
            'response' => 'conversation_handoff',
            'handoff_tool_called' => true,
            'handoff_authorized' => true,
            'handoff_reason' => 'Internal reason that must stay internal',
            'handoff_message' => 'I’ll connect you with a specialist who can continue from here.'
          }
        )

        described_class.perform_now(conversation, assistant)

        public_message = conversation.reload.messages.outgoing.where(private: false).last
        expect(public_message.content).to eq('Сотрудник продолжит диалог с вами.')
        expect(public_message.sender).to eq(assistant)
        sent = JSON.parse(request[:messages].last[:content])
        expect(sent).to include('kind' => 'handoff', 'style_guide' => 'Коротко и вежливо.')
        expect(request.to_s).not_to include('Internal reason that must stay internal')
        expect(sent).not_to have_key('reason_label')
      end

      it 'hands the notice model only the configured FAQ reason label, never the agent reason' do
        save_account_handoff_message(mode: 'generated')
        stub_notice_model
        request = {}
        allow(Llm::Runtime).to receive(:chat).with(hash_including(feature: :customer_notice)) do |**attributes|
          request.merge!(attributes)
          Struct.new(:content).new('Сотрудник продолжит диалог с вами.')
        end
        allow(agent_runner_service).to receive(:generate_response).and_return(
          {
            'response' => 'conversation_handoff',
            'handoff_tool_called' => true,
            'handoff_authorized' => true,
            'handoff_reason' => 'Internal reason',
            'handoff_outcome_signal' => 'faq_no_answer'
          }
        )

        described_class.perform_now(conversation, assistant)

        sent = JSON.parse(request[:messages].last[:content])
        expect(sent['reason_label']).to eq(I18n.t('captain.outcome_reasons.faq_no_answer', locale: account.locale))
        expect(request.to_s).not_to include('Internal reason')
      end

      it 'falls back to the fixed text, then to a neutral sentence, when the notice model fails in AI mode' do
        save_account_handoff_message(mode: 'generated', text: 'Подключаем сотрудника.')
        stub_notice_model(error: StandardError.new('boom'))

        described_class.perform_now(conversation, assistant)

        expect(conversation.reload.messages.outgoing.where(private: false).pluck(:content)).to eq(['Подключаем сотрудника.'])
      end

      it 'falls back to a neutral built-in sentence only when AI mode failed and there is no fixed text' do
        save_account_handoff_message(mode: 'generated', text: '')
        stub_notice_model(error: StandardError.new('boom'))

        described_class.perform_now(conversation, assistant)

        expect(conversation.reload.messages.outgoing.where(private: false).pluck(:content)).to eq(['Сотрудник продолжит диалог с вами.'])
      end

      it 'never calls the notice model while the handoff message is disabled, even in AI mode' do
        save_account_handoff_message(enabled: false, mode: 'generated', text: 'Подключаем сотрудника.')
        expect(Llm::Runtime).not_to receive(:chat)

        expect do
          described_class.perform_now(conversation, assistant)
        end.not_to(change { conversation.messages.outgoing.where(private: false).count })
      end

      it 'writes the notice before the conversation lock and its transaction are taken, and only once' do
        save_account_handoff_message(mode: 'generated')
        baseline_transactions = ActiveRecord::Base.connection.open_transactions
        transactions_while_writing = []
        stub_notice_model
        allow(Llm::Runtime).to receive(:chat).with(hash_including(feature: :customer_notice)) do
          transactions_while_writing << ActiveRecord::Base.connection.open_transactions
          Struct.new(:content).new('Сотрудник продолжит диалог с вами.')
        end

        described_class.perform_now(conversation, assistant)

        expect(transactions_while_writing).to eq([baseline_transactions])
        expect(conversation.reload.messages.outgoing.where(private: false).pluck(:content)).to eq(['Сотрудник продолжит диалог с вами.'])
      end

      it 'creates a private note with the handoff reason when provided by the runtime' do
        allow(agent_runner_service).to receive(:generate_response).and_return(
          {
            'response' => 'conversation_handoff',
            'handoff_tool_called' => true,
            'handoff_authorized' => true,
            'handoff_reason' => 'Customer requested billing specialist'
          }
        )

        described_class.perform_now(conversation, assistant)

        private_note = conversation.reload.messages.where(private: true).last
        expect(private_note.content).to eq('Customer requested billing specialist')
        expect(private_note.sender).to eq(assistant)
      end

      it 'defers reason classification and audits the explanation without blocking a fenced handoff' do
        buffer_token = SecureRandom.uuid
        trigger_message = conversation.messages.incoming.last
        expected_generation = conversation.captain_control_generation
        state_key = format(Redis::Alfred::CAPTAIN_MESSAGE_BUFFER_STATE, conversation_id: conversation.id)
        Redis::Alfred.set(
          state_key,
          { token: buffer_token, assistant_id: assistant.id, last_message_id: trigger_message.id }.to_json,
          ex: 10.minutes.to_i
        )
        account.update!(
          conversation_status_reason_config: {
            open: { options: ['Needs agent'], required: false }
          }
        )
        allow(Llm::EventBus).to receive(:publish)
        allow(agent_runner_service).to receive(:generate_response).and_return(
          {
            'response' => 'conversation_handoff',
            'handoff_tool_called' => true,
            'handoff_authorized' => true,
            'handoff_reason' => 'Customer requested a human',
            'handoff_status_reason' => 'handoff_requested'
          }
        )

        expect do
          described_class.perform_now(
            conversation,
            assistant,
            buffer_token: buffer_token,
            expected_last_message_id: trigger_message.id,
            expected_control_generation: expected_generation
          )
        end.not_to raise_error

        transition = conversation.reload.status_transitions.last
        expect(transition).to have_attributes(reason: Captain::OutcomeReasonConfig.new(assistant).pending_label, source: 'captain')
        expect(transition.metadata.dig('outcome_classification', 'state')).to eq('pending')
        expect(transition.metadata).to include(
          'outcome_reason_type' => 'handoff',
          'assistant_id' => assistant.id,
          'outcome_reason_explanation' => 'Customer requested a human'
        )
        expect(conversation.messages.where(private: true, content: 'Customer requested a human').count).to eq(1)
        expect(conversation.messages.where(private: true, content: described_class.new.send(:provider_error_note_content)).count).to eq(0)
        expect(Redis::Alfred.get(state_key)).to be_nil
        expect(agent_runner_service).to have_received(:generate_response).once
        expect(Llm::EventBus).not_to have_received(:publish)
          .with('captain.handoff_status_reason_dropped', anything)
      ensure
        Redis::Alfred.delete(state_key) if defined?(state_key)
      end

      it 'does not regenerate or duplicate handoff effects when the same fenced job is retried' do
        trigger_message = conversation.messages.incoming.last
        expected_generation = conversation.captain_control_generation
        save_account_handoff_message(mode: 'generated')
        stub_notice_model('Сотрудник продолжит диалог с вами.')
        allow(agent_runner_service).to receive(:generate_response).and_return(
          {
            'response' => 'conversation_handoff',
            'handoff_tool_called' => true,
            'handoff_authorized' => true,
            'handoff_reason' => 'Customer requested a person',
            'handoff_message' => 'I am connecting you with a person.'
          }
        )

        2.times do
          described_class.perform_now(
            conversation,
            assistant,
            expected_control_generation: expected_generation,
            expected_last_message_id: trigger_message.id
          )
        end

        expect(agent_runner_service).to have_received(:generate_response).once
        expect(conversation.messages.where(private: true, content: 'Customer requested a person').count).to eq(1)
        expect(conversation.messages.outgoing.where(private: false, content: 'Сотрудник продолжит диалог с вами.').count).to eq(1)
        expect(conversation.status_transitions.where(to_status: 'open').count).to eq(1)
      end

      it 'hands off with asynchronous reason classification regardless of a legacy selected reason' do
        account.update!(
          conversation_status_reason_config: {
            open: { options: ['Needs agent'], required: false }
          }
        )
        allow(agent_runner_service).to receive(:generate_response).and_return(
          {
            'response' => 'conversation_handoff',
            'handoff_tool_called' => true,
            'handoff_authorized' => true,
            'handoff_status_reason' => 'needs AGENT'
          }
        )

        described_class.perform_now(conversation, assistant)

        expect(conversation.reload.status_transitions.last).to have_attributes(reason: Captain::OutcomeReasonConfig.new(assistant).pending_label,
                                                                            source: 'captain')
      end

      it 'records the AI open activity with the handoff reason' do
        allow(agent_runner_service).to receive(:generate_response).and_return(
          {
            'response' => 'conversation_handoff',
            'handoff_tool_called' => true,
            'handoff_authorized' => true,
            'handoff_reason' => 'Customer requested billing specialist'
          }
        )

        expected_content = I18n.t(
          'conversations.activity.captain.open_with_reason',
          locale: account.locale,
          user_name: assistant.name,
          reason: 'Customer requested billing specialist'
        )

        expect { described_class.perform_now(conversation, assistant) }
          .to have_enqueued_job(Conversations::ActivityMessageJob)
          .with(conversation, { account_id: conversation.account_id, inbox_id: conversation.inbox_id, message_type: :activity,
                                content: expected_content })
      end
    end

    context 'when a provider error remains after fallback attempts' do
      before do
        allow(agent_runner_service).to receive(:generate_response).and_return(
          {
            'response' => Captain::Assistant::AgentRunnerService::PROVIDER_ERROR_RESPONSE,
            Captain::Assistant::AgentRunnerService::PROVIDER_ERROR_AUTHORIZED_KEY => true,
            'reasoning' => 'Provider error occurred: Quota exceeded',
            'error_class' => 'RubyLLM::RateLimitError',
            'error_message' => 'Quota exceeded'
          }
        )
      end

      it 'hands the conversation to people without a public transfer message' do
        expect do
          described_class.perform_now(conversation, assistant)
        end.not_to(change { conversation.messages.outgoing.where(private: false).count })

        expect(conversation.reload.status).to eq('open')
        expect(conversation.captain_handoff_applied_at).to be_present
        expect(Captain::Conversation::TypingIndicatorService).to have_received(:turn_off)
          .with(conversation: conversation, assistant: assistant).at_least(:once)
      end

      it 'creates a private note for agents without leaking provider error details' do
        described_class.perform_now(conversation, assistant)

        private_note = conversation.reload.messages.where(private: true).last
        expect(private_note.content).to eq(
          'Automatic reply could not be generated. Handoff to human agent was triggered.'
        )
        expect(private_note.content).not_to include('RubyLLM')
        expect(private_note.content).not_to include('Quota exceeded')
        expect(private_note.sender).to eq(assistant)
      end

      it 'records the failed-turn handoff activity with its inference reason after commit' do
        expected_content = I18n.t(
          'conversations.activity.captain.open_with_reason',
          locale: account.locale,
          user_name: assistant.name,
          reason: described_class::FAILED_TURN_HANDOFF_NOTE
        )

        expect { described_class.perform_now(conversation, assistant) }
          .to have_enqueued_job(Conversations::ActivityMessageJob)
          .with(conversation, { account_id: conversation.account_id, inbox_id: conversation.inbox_id, message_type: :activity,
                                content: expected_content })

        expect(conversation.reload).to be_open
        expect(conversation.captain_activity_reason).to be_nil
        expect(conversation.captain_activity_reason_type).to be_nil
      end

      it 'hands off even with the handoff tool disabled, without public transfer text' do
        assistant.update!(config: assistant.config.deep_merge(
          'tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => ['faq_lookup'] } }
        ))

        expect do
          described_class.perform_now(conversation, assistant)
        end.not_to(change { conversation.messages.outgoing.where(private: false).count })

        expect(conversation.reload.status).to eq('open')
        expect(conversation.messages.where(private: true).last.content).to eq(described_class::FAILED_TURN_HANDOFF_NOTE)
      end

      it 'sends only the configured handoff message, once, when it is configured' do
        save_account_handoff_message(text: 'Передаю администратору.')

        2.times { described_class.perform_now(conversation, assistant, expected_last_message_id: conversation.messages.incoming.last.id) }

        expect(conversation.reload.messages.outgoing.where(private: false).pluck(:content)).to eq(['Передаю администратору.'])
        expect(conversation.messages.where(private: true, content: described_class::FAILED_TURN_HANDOFF_NOTE).count).to eq(1)
      end

      it 'sends the text the notice model wrote, once, when the handoff message is in AI mode' do
        save_account_handoff_message(mode: 'generated', text: 'Передаю администратору.', instruction: 'Коротко.')
        stub_notice_model('Сотрудник продолжит диалог с вами.')

        2.times { described_class.perform_now(conversation, assistant, expected_last_message_id: conversation.messages.incoming.last.id) }

        expect(conversation.reload.messages.outgoing.where(private: false).pluck(:content)).to eq(['Сотрудник продолжит диалог с вами.'])
        expect(Llm::Runtime).to have_received(:chat).with(hash_including(feature: :customer_notice)).once
      end

      it 'falls back to the fixed text when the notice model fails in AI mode' do
        save_account_handoff_message(mode: 'generated', text: 'Передаю администратору.')
        stub_notice_model(error: Timeout::Error.new('slow'))

        described_class.perform_now(conversation, assistant)

        expect(conversation.reload.messages.outgoing.where(private: false).pluck(:content)).to eq(['Передаю администратору.'])
      end

      it 'sends nothing and never calls the notice model when the handoff message is disabled' do
        save_account_handoff_message(enabled: false, mode: 'generated', text: 'Передаю администратору.')
        expect(Llm::Runtime).not_to receive(:chat)

        expect do
          described_class.perform_now(conversation, assistant)
        end.not_to(change { conversation.messages.outgoing.where(private: false).count })
      end

      it 'normalizes malformed UTF-8 in the trace before creating the private note' do
        malformed_output = "conversation payload: \xD1".b.force_encoding(Encoding::UTF_8)
        allow(agent_runner_service).to receive(:generate_response).and_return(
          {
            'response' => Captain::Assistant::AgentRunnerService::PROVIDER_ERROR_RESPONSE,
            'captain_trace' => {
              'tool_steps' => [{ 'tool_name' => 'get_conversation', 'output' => malformed_output }]
            }
          }
        )

        expect { described_class.perform_now(conversation, assistant) }.not_to raise_error

        trace = conversation.messages.where(private: true).last.additional_attributes.fetch('captain_trace')
        expect(trace.dig('tool_steps', 0, 'output')).to be_valid_encoding
        expect { JSON.generate(trace) }.not_to raise_error
      end
    end

    context 'when agent runtime returns a blank public response' do
      before do
        allow(agent_runner_service).to receive(:generate_response).and_return(
          {
            'response' => '',
            'handoff_message' => '',
            'agent_name' => 'booking_scenario'
          }
        )
      end

      it 'hands the conversation to people with a private fallback note and no public handoff message' do
        expect do
          described_class.perform_now(conversation, assistant)
        end.not_to(change { conversation.messages.outgoing.where(private: false).count })

        expect(conversation.reload.status).to eq('open')
        private_note = conversation.messages.where(private: true).last
        expect(private_note.content).to eq(
          'Automatic reply could not be generated. Handoff to human agent was triggered.'
        )
        expect(private_note.content).not_to include('BlankResponseError')
      end
    end

    context 'when message contains an image' do
      let!(:message_with_image) do
        create(
          :message,
          conversation: conversation,
          message_type: :incoming,
          content: 'Can you help with this error?'
        )
      end
      let!(:image_attachment) do
        message_with_image.attachments.create!(
          account: account,
          file_type: :image,
          external_url: 'https://example.com/error.jpg'
        )
      end

      before do
        image_attachment
        conversation.messages.where.not(id: message_with_image.id).destroy_all
      end

      it 'includes image URL directly in the message history for vision analysis' do
        expect(agent_runner_service).to receive(:generate_response) do |message_history:|
          last_entry = message_history.last
          expect(last_entry[:content]).to be_an(Array)
          expect(last_entry[:content].any? { |part| part[:type] == 'text' && part[:text] == 'Can you help with this error?' }).to be(true)
          expect(last_entry[:content].any? do |part|
            part[:type] == 'image_url' && part[:image_url][:url] == 'https://example.com/error.jpg'
          end).to be(true)

          { 'response' => 'I can see the error in your image. It appears to be a database connection issue.' }
        end

        described_class.perform_now(conversation, assistant)
      end

      it 'marks an image sent after a receipt request as payment proof context' do
        assistant.update!(config: assistant.config.merge('history_message_limit' => 10))
        create(
          :message,
          conversation: conversation,
          account: account,
          inbox: inbox,
          message_type: :outgoing,
          sender: assistant,
          content: 'Пришлите, пожалуйста, фото чека после оплаты.',
          created_at: 2.minutes.ago
        )
        message_with_image.update!(content: nil, created_at: 1.minute.ago)

        expect(agent_runner_service).to receive(:generate_response) do |message_history:|
          last_entry = message_history.last
          expect(last_entry[:role]).to eq('user')
          expect(last_entry[:content]).to be_an(Array)
          expect(last_entry[:content].any? do |part|
            part[:type] == 'text' && part[:text].include?('Treat the image as the requested receipt/payment confirmation')
          end).to be(true)
          expect(last_entry[:content].any? do |part|
            part[:type] == 'image_url' && part[:image_url][:url] == 'https://example.com/error.jpg'
          end).to be(true)

          { 'response' => 'Спасибо, чек получил. Подтверждаю бронь.' }
        end

        described_class.perform_now(conversation, assistant)
      end

      it 'marks payment screenshots as receipt context without treating ordinary screenshots as receipts' do
        assistant.update!(config: assistant.config.merge('history_message_limit' => 10))
        create(
          :message,
          conversation: conversation,
          account: account,
          inbox: inbox,
          message_type: :outgoing,
          sender: assistant,
          content: 'Скиньте, пожалуйста, скрин оплаты.',
          created_at: 2.minutes.ago
        )
        message_with_image.update!(content: nil, created_at: 1.minute.ago)

        expect(agent_runner_service).to receive(:generate_response) do |message_history:|
          last_entry = message_history.last
          expect(last_entry[:content].any? do |part|
            part[:type] == 'text' && part[:text].include?('Treat the image as the requested receipt/payment confirmation')
          end).to be(true)

          { 'response' => 'Спасибо, оплату вижу.' }
        end

        described_class.perform_now(conversation, assistant)

        conversation.messages.where.not(id: message_with_image.id).destroy_all
        create(
          :message,
          conversation: conversation,
          account: account,
          inbox: inbox,
          message_type: :outgoing,
          sender: assistant,
          content: 'Пришлите, пожалуйста, скрин ошибки.',
          created_at: 2.minutes.ago
        )
        message_with_image.update!(content: nil, created_at: 1.minute.ago)

        expect(agent_runner_service).to receive(:generate_response) do |message_history:|
          last_entry = message_history.last
          expect(last_entry[:content].any? do |part|
            part[:type] == 'text' && part[:text].include?('Treat the image as the requested receipt/payment confirmation')
          end).to be(false)

          { 'response' => 'Посмотрел скрин ошибки.' }
        end

        described_class.perform_now(conversation, assistant)
      end
    end

    context 'when message contains an audio attachment' do
      let!(:audio_message) do
        create(
          :message,
          conversation: conversation,
          message_type: :incoming,
          content: nil
        )
      end
      let!(:audio_attachment) do
        audio_message.attachments.create!(
          account: account,
          file_type: :audio,
          meta: {}
        )
      end

      before do
        account.update!(audio_transcriptions: true)
        audio_attachment
        conversation.messages.where.not(id: audio_message.id).destroy_all
        stub_const('Captain::Conversation::ResponseBuilderJob::AUDIO_TRANSCRIPTION_WAIT_TIMEOUT', 0.05)
        stub_const('Captain::Conversation::ResponseBuilderJob::AUDIO_TRANSCRIPTION_WAIT_INTERVAL', 0.01)
      end

      it 'waits for stored audio transcription before generating a response' do
        job = described_class.new(conversation, assistant)
        allow(job).to receive(:sleep) do |_duration|
          audio_attachment.update!(meta: { 'transcribed_text' => 'Audio transcript text' })
        end

        expect(agent_runner_service).to receive(:generate_response) do |message_history:|
          expect(message_history.last[:content]).to eq('Audio transcript text')
          { 'response' => 'I understood the voice message.' }
        end

        job.perform_now
      end

      it 'continues without audio text after the transcription wait timeout' do
        job = described_class.new(conversation, assistant)
        expect(job).to receive(:sleep).at_least(:once)
        expect(Messages::AudioTranscriptionService).not_to receive(:new)
        expect(agent_runner_service).to receive(:generate_response) do |message_history:|
          expect(message_history.last[:content]).to eq('Message without content')
          { 'response' => 'Please send the details again.' }
        end

        job.perform_now
      end

      it 'does not wait or include transcription when the AI agent capability is disabled' do
        Captain::AccountSettings.new(account).update!('understanding' => { 'voice_messages' => false })
        audio_attachment.update!(meta: { 'transcribed_text' => 'Hidden transcript' })

        job = described_class.new(conversation, assistant)
        expect(job).not_to receive(:sleep)
        expect(agent_runner_service).to receive(:generate_response) do |message_history:|
          expect(message_history.last[:content]).to eq('Message without content')
          { 'response' => 'I need more details.' }
        end

        job.perform_now
      end
    end

    context 'when message contains a document attachment' do
      let!(:document_message) do
        create(
          :message,
          conversation: conversation,
          message_type: :incoming,
          content: nil
        )
      end
      let!(:document_attachment) do
        document_message.attachments.create!(
          account: account,
          file_type: :file,
          meta: {},
          file: {
            io: StringIO.new('fake pdf'),
            filename: 'contract.pdf',
            content_type: 'application/pdf'
          }
        )
      end

      before do
        account.enable_features!('captain_integration')
        account.update!(captain_runtime: { 'web_document_parse_enabled' => true })
        allow(Captain::Tools::FirecrawlService).to receive(:configured?).and_return(true)
        document_attachment
        conversation.messages.where.not(id: document_message.id).destroy_all
        stub_const('Captain::Conversation::ResponseBuilderJob::DOCUMENT_PARSE_WAIT_TIMEOUT', 0.05)
        stub_const('Captain::Conversation::ResponseBuilderJob::DOCUMENT_PARSE_WAIT_INTERVAL', 0.01)
      end

      it 'waits for stored document text before generating a response' do
        # The stubbed sleep stores the text, so the wait ends at its first iteration. The deadline only has to be
        # long enough that the pending-state database probe cannot consume it before that first sleep.
        stub_const('Captain::Conversation::ResponseBuilderJob::DOCUMENT_PARSE_WAIT_TIMEOUT', 10)
        job = described_class.new(conversation, assistant)
        allow(job).to receive(:sleep) do
          document_attachment.update!(meta: { 'parsed_text' => 'Parsed contract text' })
        end

        expect(agent_runner_service).to receive(:generate_response) do |message_history:|
          expect(message_history.last[:content]).to eq("Document attachment: contract.pdf\nParsed contract text")
          { 'response' => 'I read the document.' }
        end

        job.perform_now
      end

      it 'continues after the document parsing wait timeout' do
        job = described_class.new(conversation, assistant)
        # The pending-state database probe can consume the short deadline before
        # the first sleep. The fallback response must still be generated.
        allow(job).to receive(:sleep)
        expect(agent_runner_service).to receive(:generate_response) do |message_history:|
          expect(message_history.last[:content]).to eq('User has shared file attachment(s): contract.pdf')
          { 'response' => 'Please confirm the document details.' }
        end

        job.perform_now
      end
    end
  end

  describe 'retry mechanisms for image processing' do
    let(:conversation) { create(:conversation, inbox: inbox, account: account, status: :pending) }
    let(:agent_runner_service) { instance_double(Captain::Assistant::AgentRunnerService) }
    let(:mock_message_builder) { instance_double(Captain::OpenAiMessageBuilderService) }

    before do
      create(:captain_inbox, captain_assistant: assistant, inbox: inbox)
      create(:message, conversation: conversation, content: 'Hello with image', message_type: :incoming)
      allow(Captain::Assistant::AgentRunnerService).to receive(:new).and_return(agent_runner_service)
      # History content is built against the shared history budget (history preset).
      allow(Captain::OpenAiMessageBuilderService).to receive(:new)
        .with(message: anything, assistant: assistant, budget: kind_of(Captain::Conversation::HistoryBudget))
        .and_return(mock_message_builder)
      allow(mock_message_builder).to receive(:generate_content).and_return('Hello with image')
      allow(agent_runner_service).to receive(:generate_response).and_return({ 'response' => 'Test response' })
    end

    context 'when ActiveStorage::FileNotFoundError occurs' do
      it 'hands the conversation to people after a file error' do
        allow(mock_message_builder).to receive(:generate_content)
          .and_raise(ActiveStorage::FileNotFoundError, 'Image file not found')

        described_class.perform_now(conversation, assistant)

        expect(conversation.reload.status).to eq('open')
      end

      it 'succeeds when no error occurs' do
        allow(mock_message_builder).to receive(:generate_content)
          .and_return('Image content processed successfully')

        described_class.perform_now(conversation, assistant)

        expect(conversation.messages.outgoing.count).to eq(1)
        expect(conversation.messages.outgoing.last.content).to eq('Test response')
      end
    end

    context 'when Faraday::BadRequestError occurs' do
      it 'hands the conversation to people after an API error' do
        allow(agent_runner_service).to receive(:generate_response)
          .and_raise(Faraday::BadRequestError, 'Bad request to image service')

        described_class.perform_now(conversation, assistant)

        expect(conversation.reload.status).to eq('open')
      end

      it 'succeeds when no error occurs' do
        allow(agent_runner_service).to receive(:generate_response)
          .and_return({ 'response' => 'Response after retry' })

        described_class.perform_now(conversation, assistant)

        expect(conversation.messages.outgoing.last.content).to eq('Response after retry')
      end
    end

    context 'when image processing fails permanently' do
      before do
        allow(mock_message_builder).to receive(:generate_content)
          .and_raise(ActiveStorage::FileNotFoundError, 'Image permanently unavailable')
      end

      it 'hands the conversation to people after max retries' do
        allow(mock_message_builder).to receive(:generate_content)
          .and_raise(StandardError, 'Max retries exceeded')

        expect(ChatwootExceptionTracker).to receive(:new).and_call_original

        described_class.perform_now(conversation, assistant)

        expect(conversation.reload.status).to eq('open')
      end
    end

    context 'when non-retryable error occurs' do
      let(:standard_error) { StandardError.new('Generic error') }

      before do
        allow(agent_runner_service).to receive(:generate_response).and_raise(standard_error)
      end

      it 'handles the error with a system handoff' do
        expect(ChatwootExceptionTracker).to receive(:new)
          .with(standard_error, account: account)
          .and_call_original

        described_class.perform_now(conversation, assistant)

        expect(conversation.reload.status).to eq('open')
        expect(conversation.status_transitions.last).to have_attributes(source: 'system', actor: assistant)
      end

      it 'creates a private note without a public handoff message' do
        expect do
          described_class.perform_now(conversation, assistant)
        end.not_to(change { conversation.messages.outgoing.where(private: false).count })
        private_note = conversation.reload.messages.where(private: true).last
        expect(private_note.content).to eq(
          'Automatic reply could not be generated. Handoff to human agent was triggered.'
        )
        expect(private_note.content).not_to include('StandardError')
        expect(private_note.content).not_to include('Generic error')
      end

      it 'hands off with a private failure note and no transfer text when the handoff tool is disabled' do
        assistant.update!(config: assistant.config.deep_merge(
          'tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => ['faq_lookup'] } }
        ))

        expect do
          described_class.perform_now(conversation, assistant)
        end.not_to(change { conversation.messages.outgoing.where(private: false).count })

        expect(conversation.reload.status).to eq('open')
        expect(conversation.messages.where(private: true).last.content).to eq(described_class::FAILED_TURN_HANDOFF_NOTE)
      end

      it 'does not inherit handoff fields from a polluted failed response' do
        job = described_class.new
        job.send(:initialize_response_context, conversation, assistant, nil, conversation.messages.incoming.last.id, 0)
        job.instance_variable_set(
          :@response,
          {
            'response' => 'conversation_handoff',
            'handoff_reason' => 'Polluted handoff reason',
            'handoff_message' => 'Polluted public handoff',
            'handoff_status_reason' => 'invalid_reason'
          }
        )
        allow(job).to receive(:log_error)
        allow(Llm::EventBus).to receive(:publish)

        expect { job.send(:handle_error, standard_error) }.not_to raise_error

        expect(conversation.reload.status).to eq('open')
        expect(conversation.status_transitions.last).to have_attributes(reason: 'Reason is being classified', source: 'system')
        expect(conversation.status_transitions.last.metadata['outcome_reason_explanation']).not_to eq('Polluted handoff reason')
        expect(conversation.messages.where(content: 'Polluted handoff reason')).to be_empty
        expect(conversation.messages.where(content: 'Polluted public handoff')).to be_empty
        expect(conversation.messages.where(private: true).last.content).to eq(
          'Automatic reply could not be generated. Handoff to human agent was triggered.'
        )
        expect(Llm::EventBus).to have_received(:publish)
          .with('captain.provider_fallback_without_status_reason', hash_including(conversation_id: conversation.id))
      end

      it 'ensures Current.executed_by is reset' do
        expect(Current).to receive(:executed_by=).with(assistant)
        expect(Current).to receive(:executed_by=).with(nil)

        described_class.perform_now(conversation, assistant)
      end
    end
  end

  describe 'job configuration' do
    it 'has retry_on configuration for retryable errors' do
      expect(described_class).to respond_to(:retry_on)
    end

    it 'defines MAX_MESSAGE_LENGTH constant' do
      expect(described_class::MAX_MESSAGE_LENGTH).to eq(10_000)
    end
  end

  describe 'out of office message after handoff' do
    let(:conversation) { create(:conversation, inbox: inbox, account: account, status: :pending) }
    let(:agent_runner_service) { instance_double(Captain::Assistant::AgentRunnerService) }

    before do
      create(:captain_inbox, captain_assistant: assistant, inbox: inbox)
      create(:message, conversation: conversation, content: 'Hello', message_type: :incoming)
      allow(Captain::Assistant::AgentRunnerService).to receive(:new).and_return(agent_runner_service)
    end

    context 'when handoff occurs outside business hours' do
      before do
        inbox.update!(
          working_hours_enabled: true,
          out_of_office_message: 'We are currently closed. Please leave your email.'
        )
        inbox.working_hours.find_by(day_of_week: Time.current.in_time_zone(inbox.timezone).wday).update!(
          closed_all_day: true,
          open_all_day: false
        )
        allow(agent_runner_service).to receive(:generate_response).and_return(
          { 'response' => 'conversation_handoff', 'handoff_tool_called' => true, 'handoff_authorized' => true }
        )
      end

      it 'sends out of office message after handoff' do
        expect do
          described_class.perform_now(conversation, assistant)
        end.to change { conversation.messages.template.count }.by(1)

        expect(conversation.reload.status).to eq('open')
        ooo_message = conversation.messages.template.last
        expect(ooo_message.content).to eq('We are currently closed. Please leave your email.')
      end
    end

    context 'when handoff occurs within business hours' do
      before do
        inbox.update!(
          working_hours_enabled: true,
          out_of_office_message: 'We are currently closed.'
        )
        inbox.working_hours.find_by(day_of_week: Time.current.in_time_zone(inbox.timezone).wday).update!(
          open_all_day: true,
          closed_all_day: false
        )
        allow(agent_runner_service).to receive(:generate_response).and_return(
          { 'response' => 'conversation_handoff', 'handoff_tool_called' => true, 'handoff_authorized' => true }
        )
      end

      it 'does not send out of office message after handoff' do
        expect do
          described_class.perform_now(conversation, assistant)
        end.not_to(change { conversation.messages.template.count })

        expect(conversation.reload.status).to eq('open')
      end
    end

    context 'when handoff occurs due to error outside business hours' do
      before do
        inbox.update!(
          working_hours_enabled: true,
          out_of_office_message: 'We are currently closed.'
        )
        inbox.working_hours.find_by(day_of_week: Time.current.in_time_zone(inbox.timezone).wday).update!(
          closed_all_day: true,
          open_all_day: false
        )
        allow(agent_runner_service).to receive(:generate_response).and_raise(StandardError, 'API error')
      end

      it 'sends out of office message after the error-triggered system handoff' do
        expect do
          described_class.perform_now(conversation, assistant)
        end.to change { conversation.messages.template.count }.by(1)

        expect(conversation.reload.status).to eq('open')
        expect(conversation.messages.template.last.content).to eq('We are currently closed.')
      end
    end

    context 'when no out of office message is configured' do
      before do
        inbox.update!(
          working_hours_enabled: true,
          out_of_office_message: nil
        )
        inbox.working_hours.find_by(day_of_week: Time.current.in_time_zone(inbox.timezone).wday).update!(
          closed_all_day: true,
          open_all_day: false
        )
        allow(agent_runner_service).to receive(:generate_response).and_return({ 'response' => 'conversation_handoff' })
      end

      it 'does not send out of office message' do
        expect do
          described_class.perform_now(conversation, assistant)
        end.not_to(change { conversation.messages.template.count })
      end
    end
  end
end
