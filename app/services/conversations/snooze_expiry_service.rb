# frozen_string_literal: true

# Ends the snooze of one conversation whose time is up (Conversations::ReopenSnoozedConversationsJob). A person (communication
# thread) wakes in ONE conversation, so one timer gives at most one conversation_opened / conversation_status_changed event
# (the events automation rules, webhooks and reports hang on):
# - another conversation of the person is open or pending: the person is already being handled, so this one is resolved
#   silently into it, without any event (CommunicationThreads::SingleOpenDialogService);
# - otherwise one conversation opens: of the snoozed conversations of the person whose time is up, the one a person is reached
#   in (CommunicationThreads::SingleOpenDialogPlanner#conversation_to_keep). The refresh of the thread after it resolves the
#   other snoozed conversations of the person silently, by the same rule.
# A conversation outside a thread (an account without communication threads) simply opens, as before.
class Conversations::SnoozeExpiryService
  FEATURE_NAME = 'communication_threads'
  OPEN_STATUSES = CommunicationThreads::SingleOpenDialogPlanner::OPEN_STATUSES
  ACTIVE_STATUSES = CommunicationThreads::SingleOpenDialogPlanner::ACTIVE_STATUSES

  def initialize(conversation)
    @conversation_id = conversation.id
  end

  def perform
    # The job reads the conversations in batches: the wake-up of another conversation of the same person may have settled this
    # one in the meantime, so it is read again.
    conversation = Conversation.find_by(id: @conversation_id)
    return unless conversation && due?(conversation)

    thread = communication_thread_for(conversation)
    return conversation.open! if thread.blank?
    return if settled_into_open_dialog?(thread)

    conversation_to_open(thread, conversation).open!
  end

  private

  def due?(conversation)
    conversation.snoozed? && conversation.snoozed_until.present? && conversation.snoozed_until <= Time.current
  end

  def communication_thread_for(conversation)
    return unless conversation.account.feature_enabled?(FEATURE_NAME)

    conversation.communication_thread
  end

  # True when the person already has an open or pending dialog and this conversation was resolved into it, or waits for a live
  # call there to end (the plan is deferred and the next run of the job decides again).
  def settled_into_open_dialog?(thread)
    return false if active_conversations(thread).none? { |conversation| OPEN_STATUSES.include?(conversation.status) }

    CommunicationThreads::SingleOpenDialogService.new(thread: thread).perform.present?
  end

  def conversation_to_open(thread, conversation)
    due = active_conversations(thread).select { |candidate| due?(candidate) }
    return conversation if due.size < 2

    CommunicationThreads::SingleOpenDialogPlanner.new(thread: thread, conversations: due).conversation_to_keep || conversation
  end

  def active_conversations(thread)
    Conversation.where(account_id: thread.account_id, status: ACTIVE_STATUSES)
                .where(id: CommunicationThreadConversation.where(communication_thread_id: thread.id).select(:conversation_id))
                .includes(:inbox)
                .order(:id)
                .to_a
  end
end
