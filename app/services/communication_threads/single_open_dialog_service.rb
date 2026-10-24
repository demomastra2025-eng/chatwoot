# frozen_string_literal: true

# One person, one open dialog. When two or more conversations of a communication thread (one per contact) are open or
# pending, one stays and the others are resolved silently:
# - no message to the customer, no CSAT, and no automation rule, webhook, report or integration reacts (the conversations
#   are saved with skip_runtime_events, the status change is recorded in conversation_status_transitions with source
#   "system" and the dashboards are told through the realtime listener only),
# - the labels, the assignee, the team and the "waiting for a callback" state are kept (see
#   CommunicationThreads::SingleOpenDialogCarryOver),
# - the kept conversation gets an activity note that says what was merged.
#
# The caller is the thread resolver (so it runs on every new conversation, reopening and new activity) and the one-off
# cleanup task. With dry_run it only returns the plan and writes nothing.
class CommunicationThreads::SingleOpenDialogService
  Plan = CommunicationThreads::SingleOpenDialogPlanner::Plan
  OPEN_STATUSES = CommunicationThreads::SingleOpenDialogPlanner::OPEN_STATUSES
  MERGED_NOTE_ATTRIBUTE = 'single_open_dialog_merged_conversation_id'

  # Threads of the account (all accounts when nil) that have two or more open or pending conversations.
  def self.threads_to_consolidate(account_id: nil)
    links = CommunicationThreadConversation.joins(:conversation)
                                           .where(conversations: { status: OPEN_STATUSES })
    links = links.where(account_id: account_id) if account_id.present?
    CommunicationThread.where(id: links.group(:communication_thread_id).having('COUNT(*) > 1').select(:communication_thread_id))
  end

  # Called by the thread resolver after every refresh, so it costs nothing unless two or more of the given conversations
  # are open. The merge locks the rows of the open conversations, while the refresh before it holds the contact advisory lock
  # until the end of its transaction. Every other caller takes a conversation row first and that lock second, so when the
  # caller is itself inside a transaction (a call intake, a savepoint) the merge waits for the outermost commit instead of
  # locking rows under the advisory lock; a rollback of that transaction drops it together with the refresh. Outside a
  # transaction it runs at once. Returns the thread (not yet merged when the merge is waiting for a commit).
  def self.enforce(thread, conversations, preferred_conversation_id = nil)
    return thread if conversations.count { |conversation| OPEN_STATUSES.include?(conversation.status) } < 2

    enforced_thread = thread
    ActiveRecord.after_all_transactions_commit { enforced_thread = consolidate(thread, preferred_conversation_id) }
    enforced_thread
  end

  # A failure must never break the message or status change that triggered the refresh: it is logged and the thread is
  # returned as it was. The conversations are read again under lock by #perform, so a merge that waited for a commit
  # decides on the committed state.
  def self.consolidate(thread, preferred_conversation_id)
    new(thread: thread, preferred_conversation_id: preferred_conversation_id).perform
    thread.reload
  rescue StandardError => e
    Rails.logger.warn("[CommunicationThreads] single open dialog skipped thread=#{thread&.id}: #{e.class}: #{e.message}")
    thread
  end
  private_class_method :consolidate

  def initialize(thread:, preferred_conversation_id: nil, dry_run: false)
    @thread = thread
    @preferred_conversation_id = preferred_conversation_id
    @dry_run = dry_run
  end

  # Returns a Plan, or nil when the thread has fewer than two open conversations. A plan with an empty closed list was
  # deferred (a call is live) and changed nothing.
  def perform
    return plan_for(open_conversations) if @dry_run

    plan = nil
    kept_changed = false
    # A savepoint when the caller is in a transaction: a failure here rolls back only the merge.
    ActiveRecord::Base.transaction(requires_new: true) do
      plan = plan_for(open_conversations(lock: true))
      kept_changed = apply(plan) if plan&.closed.present?
    end
    announce_after_commit(plan, kept_changed) if plan&.closed.present?
    plan
  end

  private

  def open_conversations(lock: false)
    scope = Conversation.where(account_id: @thread.account_id, status: OPEN_STATUSES)
                        .where(id: CommunicationThreadConversation.where(communication_thread_id: @thread.id).select(:conversation_id))
                        .includes(:inbox)
                        .order(:id)
    # Rows are locked in id order, and only rows: the thread resolver takes a conversation row and then the contact
    # advisory lock, so taking the advisory lock after row locks here would invert that order. Nothing here may run while
    # that advisory lock is held, which is why .enforce waits for the commit of an open transaction.
    lock ? scope.lock.to_a : scope.to_a
  end

  def plan_for(conversations)
    CommunicationThreads::SingleOpenDialogPlanner.new(
      thread: @thread, conversations: conversations, preferred_conversation_id: @preferred_conversation_id
    ).perform
  end

  def apply(plan)
    plan.closed.each { |conversation| resolve_silently!(conversation, plan.kept) }
    kept_changed = CommunicationThreads::SingleOpenDialogCarryOver.perform(plan)
    Conversations::CommunicationThreadResolver.new(conversation: plan.kept, enforce_single_open_dialog: false).perform
    kept_changed
  end

  def resolve_silently!(conversation, kept)
    conversation.skip_runtime_events = true
    conversation.skip_activity_messages = true
    conversation.skip_communication_thread_refresh = true
    Conversations::StatusTransitionService.new(
      conversation: conversation,
      params: { status: 'resolved' },
      actor: nil,
      source: 'system',
      audit: { metadata: { 'single_open_dialog' => { 'kept_conversation_id' => kept.id } } }
    ).perform
  end

  def announce_after_commit(plan, kept_changed)
    ActiveRecord.after_all_transactions_commit do
      plan.closed.each { |conversation| add_merge_note(plan.kept, conversation) }
      broadcast(plan, kept_changed)
    rescue StandardError => e
      Rails.logger.warn("[CommunicationThreads] single open dialog notes skipped thread=#{@thread.id}: #{e.class}: #{e.message}")
    end
  end

  def add_merge_note(kept, merged)
    Conversations::ActivityMessageJob.perform_later(
      kept,
      {
        account_id: kept.account_id,
        inbox_id: kept.inbox_id,
        message_type: :activity,
        content: merge_note(kept.account, merged),
        additional_attributes: { MERGED_NOTE_ATTRIBUTE => merged.id }
      }
    )
  end

  def merge_note(account, merged)
    key = CommunicationThreads::SingleOpenDialogPlanner.voice?(merged) ? 'merged_call' : 'merged_dialog'
    locale = account.locale.presence
    I18n.with_locale(locale && I18n.locale_available?(locale) ? locale : I18n.default_locale) do
      I18n.t("conversations.activity.single_open_dialog.#{key}", channel: merged.inbox.name)
    end
  end

  # Dashboards only: the realtime listener, not the dispatcher, so webhooks, automation rules and reports stay quiet.
  def broadcast(plan, kept_changed)
    listener = ActionCableListener.instance
    plan.closed.each do |conversation|
      listener.conversation_status_changed(realtime_event(Events::Types::CONVERSATION_STATUS_CHANGED, conversation))
    end
    listener.conversation_updated(realtime_event(Events::Types::CONVERSATION_UPDATED, plan.kept)) if kept_changed
  end

  def realtime_event(name, conversation)
    Events::Base.new(name, Time.zone.now, conversation: conversation)
  end
end
