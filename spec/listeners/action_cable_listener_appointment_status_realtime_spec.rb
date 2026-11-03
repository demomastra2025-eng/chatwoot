require 'rails_helper'

RSpec.describe ActionCableListener do
  # Observe the actual after_update_commit boundary, not savepoint callbacks in
  # the example's wrapping transaction. CommittedRowsCleanup requires an own test DB.
  self.use_transactional_tests = false

  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:first_agent) { create(:user, account: account, role: :agent) }
  let(:second_agent) { create(:user, account: account, role: :agent) }
  let(:first_inbox) { create(:inbox, account: account) }
  let(:second_inbox) { create(:inbox, account: account) }
  let(:first_conversation) { create(:conversation, account: account, contact: contact, inbox: first_inbox, status: :resolved) }
  let(:second_conversation) { create(:conversation, account: account, contact: contact, inbox: second_inbox, status: :resolved) }
  let(:appointment) do
    create(:scheduling_appointment, account: account, contact: contact, conversation: first_conversation,
                                    source: 'medelement', status: 'scheduled')
  end
  let(:broadcasts) { [] }

  before do
    account.enable_features!('scheduling', 'communication_threads')
    admin
    create(:inbox_member, inbox: first_inbox, user: first_agent)
    create(:inbox_member, inbox: second_inbox, user: second_agent)
    InboxMember.where(inbox: first_inbox, user: second_agent).delete_all
    InboxMember.where(inbox: second_inbox, user: first_agent).delete_all
    first_conversation.refresh_communication_thread!
    second_conversation.refresh_communication_thread!
    appointment
    # Only the real synchronous realtime listener is exercised. Do not run
    # provider/CRM/automation reactions while testing dashboard invalidation.
    allow(Rails.configuration.dispatcher.async_dispatcher).to receive(:dispatch)
    allow(ActionCableBroadcastJob).to receive(:perform_later) do |tokens, event, payload|
      final_payload = ActionCableBroadcastJob.new.send(:prepare_broadcast_data, event, payload)
      broadcasts << [tokens, event, final_payload]
    end
    clear_enqueued_jobs
  end

  def confirm!
    reminder = instance_double(Reminder, response_action: 'confirm_appointment', remindable: appointment, metadata: {})
    request = instance_double(ConfirmationRequest, account: account, account_id: account.id, reminder: reminder, subject: appointment)
    Confirmations::ResponseActionService.new(confirmation_request: request, decision: 'confirmed').perform
  end

  def thread_broadcasts
    broadcasts.select { |_tokens, event, _payload| event == 'communication_thread.updated' }
  end

  def conversation_broadcasts
    broadcasts.select { |_tokens, event, _payload| event == 'conversation.updated' }
  end

  # This regression observes the whole early-snapshot/commit/recipient sequence.
  it 'replaces an early scheduled snapshot after confirmation commits, once per thread recipient and only through visible channels' do # rubocop:disable RSpec/MultipleExpectations
    thread = first_conversation.reload.communication_thread
    expect(second_conversation.reload.communication_thread).to eq(thread)
    CommunicationThreads::RealtimeUpdateService.new(
      communication_thread_id: thread.id, source_conversation_id: first_conversation.id, source_event: 'message.created'
    ).perform
    expect(thread_broadcasts).not_to be_empty
    expect(thread_broadcasts.map { |_tokens, _event, payload| payload[:scheduling_appointment_statuses] }.uniq)
      .to eq([[{ status: 'scheduled', count: 1 }]])
    broadcasts.clear
    clear_enqueued_jobs

    # Observe the final job-prepared payload, not only the listener's queued data.
    # Two siblings still enqueue only one thread refresh for this transition.
    Scheduling::Appointment.transaction do
      expect(confirm!).to eq('appointment_confirmed')
      expect(broadcasts).to be_empty
      expect(enqueued_jobs.none? { |job| job[:job] == CommunicationThreads::RealtimeUpdateJob }).to be(true)
    end
    expect(appointment.reload.status).to eq('confirmed')
    expect(conversation_broadcasts.map { |_tokens, _event, payload| payload[:id] })
      .to contain_exactly(first_conversation.display_id, second_conversation.display_id)
    expect(conversation_broadcasts.map { |_tokens, _event, payload| payload[:scheduling_appointment_statuses] }.uniq)
      .to eq([[{ status: 'confirmed', count: 1 }]])
    refreshes = enqueued_jobs.select { |job| job[:job] == CommunicationThreads::RealtimeUpdateJob }
    expect(refreshes.size).to eq(1)

    perform_enqueued_jobs(only: CommunicationThreads::RealtimeUpdateJob)
    [admin, first_agent, second_agent].each do |user|
      updates = thread_broadcasts.select { |tokens, _event, _payload| tokens.include?(user.pubsub_token) }
      expect(updates.size).to eq(1)
      expect(updates.sole.last).to include(
        account_id: account.id, scheduling_appointment_statuses: [{ status: 'confirmed', count: 1 }]
      )
    end
    [[first_agent, first_conversation], [second_agent, second_conversation]].each do |user, visible_conversation|
      payload = thread_broadcasts.find { |tokens, _event, _payload| tokens.include?(user.pubsub_token) }.last
      expect(payload[:conversation_ids]).to eq([visible_conversation.display_id])
      expect(payload[:conversation_id]).to eq(visible_conversation.display_id)
      expect(payload[:inbox_id]).to eq(visible_conversation.inbox_id)
    end
  end

  it 'excludes unrelated dialogs, other accounts and unauthorized operators from status updates' do
    unrelated = create(:conversation, account: account)
    outsider = create(:user, account: account, role: :agent)
    foreign = create(:conversation)
    foreign_admin = create(:user, account: foreign.account, role: :administrator)
    # AccountUser creation joins every active inbox. Build an actually hidden
    # legacy membership fixture before asserting that this operator is excluded.
    InboxMember.where(user: outsider, inbox: [first_inbox, second_inbox]).delete_all
    membership = account.account_users.find_by!(user_id: outsider.id)
    expect(membership).to be_agent
    policy_context = { user: outsider, account: account, account_user: membership }
    expect([first_conversation, second_conversation].map { |conversation| ConversationPolicy.new(policy_context, conversation.reload).show? })
      .to eq([false, false])
    broadcasts.clear
    clear_enqueued_jobs

    confirm!
    perform_enqueued_jobs(only: CommunicationThreads::RealtimeUpdateJob)

    expect(conversation_broadcasts.map { |_tokens, _event, payload| payload[:id] })
      .not_to include(unrelated.display_id)
    expect(broadcasts.flat_map(&:first)).not_to include(outsider.pubsub_token, foreign_admin.pubsub_token)
    expect(broadcasts.map { |_tokens, _event, payload| payload[:account_id] }.uniq).to eq([account.id])
    expect(thread_broadcasts.map { |_tokens, _event, payload| payload[:communication_thread_id] }.uniq)
      .to eq([first_conversation.reload.communication_thread.display_id])
  end

  it 'does not publish a status update rolled back with its appointment transaction' do
    Scheduling::Appointment.transaction do
      confirm!
      expect(broadcasts).to be_empty
      raise ActiveRecord::Rollback
    end

    expect(appointment.reload.status).to eq('scheduled')
    expect(conversation_broadcasts).to be_empty
    expect(enqueued_jobs.none? { |job| job[:job] == CommunicationThreads::RealtimeUpdateJob }).to be(true)
  end

  it 'does not invalidate dialogs for unrelated field edits or repeated confirmation' do
    appointment.update!(duration_min: appointment.duration_min)
    appointment.update!(client_name: 'Synthetic updated name')
    expect(conversation_broadcasts).to be_empty
    expect(enqueued_jobs.none? { |job| job[:job] == CommunicationThreads::RealtimeUpdateJob }).to be(true)

    confirm!
    broadcasts.clear
    clear_enqueued_jobs
    expect(confirm!).to eq('already_confirmed')
    expect(broadcasts).to be_empty
    expect(enqueued_jobs.none? { |job| job[:job] == CommunicationThreads::RealtimeUpdateJob }).to be(true)
  end

  it 'publishes the current canonical snapshot for another status edit' do
    appointment.update!(status: 'cancelled')
    expect(conversation_broadcasts.map { |_tokens, _event, payload| payload[:scheduling_appointment_statuses] }.uniq)
      .to eq([[{ status: 'cancelled', count: 1 }]])
    expect(enqueued_jobs.count { |job| job[:job] == CommunicationThreads::RealtimeUpdateJob }).to eq(1)
  end

  it 'keeps source-less refreshes restricted to appointment status events' do
    expect do
      CommunicationThreads::RealtimeUpdateService.new(
        communication_thread_id: first_conversation.reload.communication_thread.id, source_event: 'message.created'
      )
    end.to raise_error(ArgumentError, /Only appointment status/)
  end
end
