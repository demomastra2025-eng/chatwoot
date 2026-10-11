# frozen_string_literal: true

require 'rails_helper'
require 'timeout'

RSpec.describe 'Captain final persistence assignment boundary', type: :job do
  self.use_transactional_tests = false

  let(:account) { create(:account, auto_resolve_after: 60, custom_attributes: { plan_name: 'startups' }) }
  let(:inbox) { create(:inbox, account: account) }
  let(:entry) { create(:captain_assistant, account: account) }
  let(:actor) do
    create(:captain_assistant, account: account, config: {
             'resolution_message_enabled' => true, 'resolution_message_mode' => 'static', 'resolution_message' => 'Specialist closure',
             'handoff_enabled' => true, 'handoff_message_enabled' => true,
             'handoff_message_mode' => 'static', 'handoff_message' => 'Specialist transfer'
           })
  end
  let(:conversation) { create(:conversation, account: account, inbox: inbox, status: :pending) }

  around do |example|
    ActiveRecord::Base.connection
    pool = ActiveRecord::Base.connection_pool
    @writer_connection = pool.checkout
    example.run
  ensure
    pool.checkin(@writer_connection) if @writer_connection
  end

  before do
    account.enable_features!('captain_integration', 'captain_tasks')
    create(:captain_inbox, inbox: inbox, captain_assistant: entry)
    entry.update!(handoff_agent_ids: [actor.id])
    create(:message, conversation: conversation, sender: conversation.contact,
                     message_type: :incoming, skip_runtime_events: true)
    Captain::Conversation::AgentSession.new(entry: entry, conversation: conversation).update_routing(actor_id: actor.id)
    conversation.update_column(:last_activity_at, 2.hours.ago)
    allow(Captain::Conversation::TypingIndicatorService).to receive(:turn_on)
    allow(Captain::Conversation::TypingIndicatorService).to receive(:turn_off)
  end

  after { CommittedRowsCleanup.truncate! }

  def writer_can_acquire?
    lock_id = Telephony::AiVoice::AssistantAssignmentLock.send(:lock_id_for, inbox.id)
    @writer_connection.transaction(requires_new: true) do
      @writer_connection.select_value("SELECT pg_try_advisory_xact_lock(#{lock_id})")
    end
  end

  def response_job(response)
    runner = instance_double(Captain::Assistant::AgentRunnerService)
    allow(Captain::Assistant::AgentRunnerService).to receive(:new).and_return(runner)
    allow(runner).to receive(:generate_response) do
      expect(writer_can_acquire?).to be(true)
      { 'agent_id' => actor.id, 'agent_name' => "assistant_#{actor.id}" }.merge(response)
    end
    Captain::Conversation::ResponseBuilderJob.new
  end

  def completion_job
    evaluator = instance_double(Captain::ConversationCompletionService)
    allow(evaluator).to receive(:perform) do
      expect(writer_can_acquire?).to be(true)
      { complete: true, reason: 'Answered' }
    end
    allow(Captain::ConversationCompletionService).to receive(:new).and_return(evaluator)
    Captain::InboxPendingConversationsResolutionJob.new
  end

  # Commit the competing CaptainInbox writer precisely before final lock
  # acquisition. Its own before_save takes the same advisory lock; no timing
  # delays are needed, and the writer runs on a separate PostgreSQL connection.
  def reassign_before_final_lock(replacement)
    reassigned = false
    allow(Telephony::AiVoice::AssistantAssignmentLock).to receive(:acquire!).and_wrap_original do |original, inbox_id|
      unless reassigned || Thread.current[:captain_assignment_writer]
        reassigned = true
        writer = Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            Thread.current[:captain_assignment_writer] = true
            CaptainInbox.find_by!(inbox_id: inbox_id).update!(captain_assistant: replacement)
          end
        end
        Timeout.timeout(10) { writer.value }
      end
      original.call(inbox_id)
    end
  end

  it 'holds the assignment fence through completion messages and releases it after persistence' do
    job = completion_job
    expect(job).to receive(:create_private_note).and_wrap_original do |original, *arguments|
      expect(writer_can_acquire?).to be(false)
      original.call(*arguments)
    end

    job.perform(inbox)

    expect(conversation.reload).to be_resolved
    expect(conversation.messages.outgoing.where(private: false).last.sender).to eq(actor)
    expect(writer_can_acquire?).to be(true)
  end

  it 'rereads completion ownership after a channel assignment commits before final acquisition' do
    replacement = create(:captain_assistant, account: account)
    job = completion_job
    reassign_before_final_lock(replacement)

    job.perform(inbox)

    expect(CaptainInbox.find_by!(inbox_id: inbox.id).captain_assistant_id).to eq(replacement.id)
    expect(conversation.reload).to be_pending
    expect(conversation.messages.outgoing).to be_empty
    expect(writer_can_acquire?).to be(true)
  end

  it 'holds the assignment fence through reply materialization without holding it during generation' do
    job = response_job('response' => 'Specialist answer')
    expect(job).to receive(:create_messages).and_wrap_original do |original, **arguments|
      expect(writer_can_acquire?).to be(false)
      original.call(**arguments)
    end

    job.perform(conversation, entry)

    expect(conversation.messages.outgoing.where(private: false).last).to have_attributes(content: 'Specialist answer', sender: actor)
    expect(writer_can_acquire?).to be(true)
  end

  it 'rereads reply ownership after a channel assignment commits before final acquisition' do
    replacement = create(:captain_assistant, account: account)
    job = response_job('response' => 'Stale specialist answer')
    reassign_before_final_lock(replacement)

    job.perform(conversation, entry)

    expect(CaptainInbox.find_by!(inbox_id: inbox.id).captain_assistant_id).to eq(replacement.id)
    expect(conversation.messages.outgoing).to be_empty
    expect(writer_can_acquire?).to be(true)
  end

  it 'holds the assignment fence through authorized handoff messages' do
    job = response_job('response' => 'conversation_handoff', 'handoff_tool_called' => true, 'handoff_authorized' => true)
    expect(job).to receive(:create_private_note).and_wrap_original do |original, *arguments|
      expect(writer_can_acquire?).to be(false)
      original.call(*arguments)
    end

    job.perform(conversation, entry)

    expect(conversation.reload).to be_open
    expect(conversation.messages.outgoing.where(private: false).last).to have_attributes(content: 'Specialist transfer', sender: actor)
    expect(writer_can_acquire?).to be(true)
  end

  it 'holds the assignment fence through failure handoff messages' do
    job = response_job('response' => Captain::Assistant::AgentRunnerService::PROVIDER_ERROR_RESPONSE)
    expect(job).to receive(:create_private_note).and_wrap_original do |original, *arguments|
      expect(writer_can_acquire?).to be(false)
      original.call(*arguments)
    end

    job.perform(conversation, entry)

    expect(conversation.reload).to be_open
    expect(conversation.messages.outgoing.where(private: false).last).to have_attributes(content: 'Specialist transfer', sender: actor)
    expect(writer_can_acquire?).to be(true)
  end
end
