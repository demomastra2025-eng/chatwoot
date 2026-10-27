class Conversations::CommunicationThreadResolver # rubocop:disable Metrics/ClassLength
  # The status of a person, from the most urgent to the least: open before pending (a bot has it) before snoozed before
  # resolved. A person is resolved only when every channel is.
  STATUS_URGENCY = %w[open pending snoozed resolved].freeze

  class << self
    # The conversations of a person, the one in front first: the conversation whose status the thread shows (the most
    # urgent not resolved one, the one that changed last among equals, see #aggregate_status), then the other not resolved
    # ones, then the resolved ones by their last activity. A change of the whole person that is reported by one conversation
    # is reported by the first.
    def front_first(conversations)
      active, resolved = Array(conversations).partition { |conversation| !conversation.resolved? }
      active.sort_by { |c| [-status_urgency(c.status), *status_sort_key(c)] }.reverse +
        resolved.sort_by { |c| activity_sort_key(c) }.reverse
    end

    # The conversation in front of a thread (see front_first): the one a display id of the thread stands for. nil without one.
    def front_conversation(thread)
      return if thread.blank?

      front_first(thread.conversations.where(account_id: thread.account_id).to_a).first
    end

    # The index of a status in STATUS_URGENCY: lower is more urgent.
    def status_urgency(status)
      STATUS_URGENCY.index(status) || STATUS_URGENCY.size
    end

    def status_sort_key(conversation)
      [conversation.updated_at || conversation.last_activity_at, conversation.id]
    end

    def activity_sort_key(conversation)
      [conversation.last_activity_at || conversation.updated_at, conversation.id]
    end
  end

  # enforce_single_open_dialog: after the thread is refreshed, keep one open dialog per person, see
  # CommunicationThreads::SingleOpenDialogService. preferred_conversation_id is the conversation a person has just
  # reopened by hand: it stays when several are open. Callers that only repair thread links (the backfill) and the
  # service itself, which refreshes the thread after resolving, pass false.
  def initialize(conversation:, enforce_single_open_dialog: true, preferred_conversation_id: nil)
    # Conversation DB triggers populate display_id/uuid after insert and the
    # originating instance can still report those attributes as dirty. Locking
    # that instance raises in Active Record, so resolve against a fresh copy
    # without clearing the caller's saved_changes used by event dispatchers.
    @conversation = conversation&.persisted? ? conversation.class.find(conversation.id) : conversation
    @enforce_single_open_dialog = enforce_single_open_dialog
    @preferred_conversation_id = preferred_conversation_id
  end

  def perform
    return unless linkable_conversation?

    thread = refresh_linked_thread
    return thread unless thread && @enforce_single_open_dialog

    # Two or more open or pending conversations in the thread, or an open or pending one next to a snoozed one: all but one are
    # resolved silently, outside the transaction of the refresh. So an incoming message wakes the whole person: the conversation
    # that received it opens and a snoozed channel of the same person does not keep its timer (which would open it again later
    # with its own status events). When the caller is inside a transaction of its own (the intake of a call, for one), the refresh above
    # joined it and its contact advisory lock is held until that transaction ends, so the merge waits for the commit, see
    # CommunicationThreads::SingleOpenDialogService.enforce for the lock order.
    CommunicationThreads::SingleOpenDialogService.enforce(thread, linked_conversations(thread), @preferred_conversation_id)
  end

  private

  attr_reader :conversation

  def refresh_linked_thread
    CommunicationThread.transaction do
      conversation.lock!
      next unless linkable_conversation?

      locked_account_id = conversation.account_id
      locked_contact_id = conversation.contact_id
      lock_contact_thread!(locked_account_id, locked_contact_id)
      next unless conversation.account_id == locked_account_id && conversation.contact_id == locked_contact_id

      previous_thread = raw_communication_thread
      thread = existing_thread || build_thread
      thread.save! if thread.new_record?
      create_or_update_link!(thread)
      reset_conversation_thread_associations
      refresh_thread!(thread)
      refresh_previous_thread!(previous_thread, thread)
      thread
    end
  end

  def lock_contact_thread!(account_id, contact_id)
    CommunicationThreads::PersonLock.lock!(account_id: account_id, contact_id: contact_id)
  end

  def linkable_conversation?
    return false if conversation.blank? || conversation.destroyed? || conversation.marked_for_destruction?
    return false if conversation.account_id.blank? || conversation.contact_id.blank?
    return false if conversation.inbox_id.blank? || conversation.contact_inbox_id.blank?
    return false unless Inbox.exists?(id: conversation.inbox_id, account_id: conversation.account_id)
    return false unless Contact.exists?(id: conversation.contact_id, account_id: conversation.account_id)
    return false unless ContactInbox.exists?(id: conversation.contact_inbox_id, inbox_id: conversation.inbox_id, contact_id: conversation.contact_id)

    true
  end

  def existing_thread
    linked_thread = raw_communication_thread
    return linked_thread if linked_thread&.account_id == conversation.account_id && linked_thread.contact_id == conversation.contact_id

    CommunicationThread.of_person(account_id: conversation.account_id, contact_id: conversation.contact_id)
  end

  def raw_communication_thread
    conversation.association(:communication_thread).reader
  end

  def build_thread
    CommunicationThread.new(
      account_id: conversation.account_id,
      contact_id: conversation.contact_id,
      status: conversation.status,
      priority: conversation.priority,
      assignee_id: conversation.contact&.owner_id || conversation.assignee_id,
      team_id: conversation.team_id,
      last_activity_at: conversation.last_activity_at,
      unread_count: conversation.unread_incoming_messages_count
    )
  end

  def create_or_update_link!(thread)
    existing_link = CommunicationThreadConversation.find_by(
      account_id: conversation.account_id,
      conversation_id: conversation.id
    )
    return update_link!(existing_link, thread) if existing_link.present?

    CommunicationThreadConversation.create!(
      account_id: conversation.account_id,
      communication_thread_id: thread.id,
      conversation_id: conversation.id,
      inbox_id: conversation.inbox_id,
      contact_inbox_id: conversation.contact_inbox_id,
      primary: CommunicationThreadConversation.where(communication_thread_id: thread.id).none?
    )
  end

  def update_link!(link, thread)
    link.update!(
      communication_thread_id: thread.id,
      inbox_id: conversation.inbox_id,
      contact_inbox_id: conversation.contact_inbox_id,
      primary: link_primary_value(link, thread)
    )
  end

  def link_primary_value(link, thread)
    return link.primary? if link.communication_thread_id == thread.id

    CommunicationThreadConversation
      .where(communication_thread_id: thread.id)
      .where.not(id: link.id)
      .none?
  end

  def reset_conversation_thread_associations
    conversation.association(:communication_thread_conversation).reset
    conversation.association(:communication_thread).reset
  end

  def refresh_previous_thread!(previous_thread, current_thread)
    return if previous_thread.blank? || previous_thread.id == current_thread.id
    return unless previous_thread.account_id == conversation.account_id
    return unless previous_thread.contact&.account_id == conversation.account_id

    previous_thread.reload
    if previous_thread.communication_thread_conversations.exists?
      ensure_primary_link!(previous_thread)
      refresh_thread!(previous_thread)
    else
      previous_thread.destroy!
    end
  end

  def ensure_primary_link!(thread)
    primary_link_exists = CommunicationThreadConversation.exists?(
      communication_thread_id: thread.id,
      primary: true
    )
    return if primary_link_exists

    CommunicationThreadConversation
      .where(communication_thread_id: thread.id)
      .order(:created_at, :id)
      .first&.update!(primary: true)
  end

  def refresh_thread!(thread)
    thread.update!(
      status: aggregate_status(thread),
      priority: aggregate_priority(thread),
      assignee_id: aggregate_assignee_id(thread),
      team_id: aggregate_team_id(thread),
      last_activity_at: aggregate_last_activity_at(thread),
      unread_count: aggregate_unread_count(thread)
    )
  end

  # One person, one status: the most urgent status of the linked conversations wins (see STATUS_URGENCY), whichever
  # conversation was saved last. A priority change or a note on a quiet channel must not repaint the person.
  def aggregate_status(thread)
    linked_conversations(thread).map(&:status).min_by { |status| self.class.status_urgency(status) } || 'resolved'
  end

  def aggregate_priority(thread)
    linked_conversations(thread).filter_map(&:priority).max_by { |priority| Conversation.priorities.fetch(priority) }
  end

  def aggregate_last_activity_at(thread)
    linked_conversations(thread).filter_map(&:last_activity_at).max || conversation.last_activity_at
  end

  def aggregate_unread_count(thread)
    conversations = linked_conversations(thread)
    return conversations.sum(&:unread_incoming_messages_count) if conversations.size <= 1

    Message.without_imported_history.reorder(nil).incoming
           .where(account_id: thread.account_id, conversation_id: conversations.map(&:id), private: false)
           .joins(:conversation).where("messages.created_at > COALESCE(conversations.agent_last_seen_at, '-infinity'::timestamp)").count
  end

  def aggregate_assignee_id(thread)
    thread.contact&.owner_id || latest_routing_conversation(thread)&.assignee_id
  end

  def aggregate_team_id(thread)
    latest_routing_conversation(thread)&.team_id
  end

  def latest_routing_conversation(thread)
    linked_conversations(thread).sort_by { |c| self.class.activity_sort_key(c) }.reverse.find { |c| routed?(c) }
  end

  def routed?(linked_conversation)
    linked_conversation.assignee_id.present? || linked_conversation.team_id.present?
  end

  def linked_conversations(thread)
    @linked_conversations ||= {}
    @linked_conversations[thread.id] ||= Conversation.where(
      account_id: thread.account_id,
      id: CommunicationThreadConversation.where(communication_thread_id: thread.id).select(:conversation_id)
    ).to_a
  end
end
