# frozen_string_literal: true

# One person, one dialog. When two or more conversations of a communication thread (one per contact) are open or pending,
# or one is open or pending and another is snoozed, one stays and the others are resolved silently. A snoozed channel next to
# an open dialog is resolved too: its timer would otherwise open a second dialog later (with its own status events) only for
# this rule to close it again, and a person written to in one channel must not stay snoozed in another.
# - no message to the customer, no CSAT, and no automation rule, webhook, report or integration reacts (the conversations
#   are saved with skip_runtime_events, the status change is recorded in conversation_status_transitions with source
#   "system" and the dashboards are told through the realtime listener only),
# - the labels, the assignee, the team and the "waiting for a callback" state are kept (see
#   CommunicationThreads::SingleOpenDialogCarryOver),
# - the kept conversation gets an activity note that says what was merged.
#
# A person whose conversations that are not resolved are all snoozed is merged only when the caller asks for it
# (all_snoozed): the person update (CommunicationThreads::UpdateService, which snoozes one conversation) and the one-off
# cleanup of the snoozes left by the old rule, which snoozed every channel of a person.
#
# The callers are the thread resolver (so it runs on every new conversation, reopening and new activity), the person update,
# the snooze expiry (Conversations::SnoozeExpiryService) and the one-off cleanup task. With dry_run it only returns the plan
# and writes nothing.
class CommunicationThreads::SingleOpenDialogService
  Plan = CommunicationThreads::SingleOpenDialogPlanner::Plan
  OPEN_STATUSES = CommunicationThreads::SingleOpenDialogPlanner::OPEN_STATUSES
  ACTIVE_STATUSES = CommunicationThreads::SingleOpenDialogPlanner::ACTIVE_STATUSES
  MERGED_NOTE_ATTRIBUTE = 'single_open_dialog_merged_conversation_id'

  # Threads of the account (all accounts when nil) that have two or more conversations that are not resolved (open, pending or
  # snoozed). Pass all_snoozed: true to the service to merge every one of them.
  def self.threads_to_consolidate(account_id: nil)
    links = CommunicationThreadConversation.joins(:conversation)
                                           .where(conversations: { status: ACTIVE_STATUSES })
    links = links.where(account_id: account_id) if account_id.present?
    CommunicationThread.where(id: links.group(:communication_thread_id).having('COUNT(*) > 1').select(:communication_thread_id))
  end

  # True when the conversations break the rule: two or more are not resolved and one of them is open or pending, or, with
  # all_snoozed, two or more are not resolved whatever their status.
  def self.consolidation_needed?(conversations, all_snoozed: false)
    active = conversations.select { |conversation| ACTIVE_STATUSES.include?(conversation.status) }
    return false if active.size < 2

    all_snoozed || active.any? { |conversation| OPEN_STATUSES.include?(conversation.status) }
  end

  # Called by the thread resolver after every refresh, so it costs nothing unless the given conversations break the rule. The
  # merge locks the rows of the conversations, while the refresh before it holds the contact advisory lock until the end of
  # its transaction. Every other caller takes a conversation row first and that lock second, so when the caller is itself
  # inside a transaction (a call intake, a savepoint) the merge waits for the outermost commit instead of locking rows under
  # the advisory lock; a rollback of that transaction drops it together with the refresh. Outside a transaction it runs at
  # once. Returns the thread (not yet merged when the merge is waiting for a commit).
  def self.enforce(thread, conversations, preferred_conversation_id = nil, all_snoozed: false)
    return thread unless consolidation_needed?(conversations, all_snoozed: all_snoozed)

    enforced_thread = thread
    ActiveRecord.after_all_transactions_commit do
      enforced_thread = consolidate(thread, preferred_conversation_id, all_snoozed)
    end
    enforced_thread
  end

  # A failure must never break the message or status change that triggered the refresh: it is logged and the thread is
  # returned as it was. The conversations are read again under lock by #perform, so a merge that waited for a commit
  # decides on the committed state.
  def self.consolidate(thread, preferred_conversation_id, all_snoozed)
    new(thread: thread, preferred_conversation_id: preferred_conversation_id, all_snoozed: all_snoozed).perform
    thread.reload
  rescue StandardError => e
    Rails.logger.warn("[CommunicationThreads] single open dialog skipped thread=#{thread&.id}: #{e.class}: #{e.message}")
    thread
  end
  private_class_method :consolidate

  def initialize(thread:, preferred_conversation_id: nil, dry_run: false, all_snoozed: false)
    @thread = thread
    @preferred_conversation_id = preferred_conversation_id
    @dry_run = dry_run
    @all_snoozed = all_snoozed
  end

  # Returns a Plan, or nil when the thread does not break the rule (see .consolidation_needed?). A plan with an empty closed
  # list was deferred (a call is live) and changed nothing.
  def perform
    return plan_for(active_conversations) if @dry_run

    plan = nil
    kept_changed = false
    # A savepoint when the caller is in a transaction: a failure here rolls back only the merge.
    ActiveRecord::Base.transaction(requires_new: true) do
      plan = plan_for(active_conversations(lock: true))
      kept_changed = apply(plan) if plan&.closed.present?
    end
    announce_after_commit(plan, kept_changed) if plan&.closed.present?
    plan
  end

  private

  def active_conversations(lock: false)
    scope = Conversation.where(account_id: @thread.account_id, status: ACTIVE_STATUSES)
                        .where(id: CommunicationThreadConversation.where(communication_thread_id: @thread.id).select(:conversation_id))
                        .includes(:inbox)
                        .order(:id)
    # Rows are locked in id order, and only rows: the thread resolver takes a conversation row and then the contact
    # advisory lock, so taking the advisory lock after row locks here would invert that order. Nothing here may run while
    # that advisory lock is held, which is why .enforce waits for the commit of an open transaction.
    lock ? scope.lock.to_a : scope.to_a
  end

  def plan_for(conversations)
    return unless self.class.consolidation_needed?(conversations, all_snoozed: @all_snoozed)

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
