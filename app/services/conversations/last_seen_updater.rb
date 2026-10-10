class Conversations::LastSeenUpdater
  pattr_initialize [:conversation!]

  def perform(last_seen_at:, update_assignee: false, refresh_communication_thread: true, broadcast_read_state: false,
              allow_regression: false, actor: Current.user)
    return if last_seen_at.blank?

    # Trigger-created display_id values can be dirty in memory even though the
    # persisted row is clean. Clear that transient state first; with_lock then
    # reloads again while holding the row lock so the cursor comparison uses
    # the latest committed shared value.
    Conversations::ReadStateTransaction.perform do
      conversation.reload.with_lock do
        shared_cursor = allow_regression ? last_seen_at : [conversation.agent_last_seen_at, last_seen_at].compact.max
        updates = { agent_last_seen_at: shared_cursor }
        updates[:assignee_last_seen_at] = last_seen_at if update_assignee

        # rubocop:disable Rails/SkipsModelValidations
        conversation.update_columns(updates)
        # rubocop:enable Rails/SkipsModelValidations
      end
    end

    conversation.dispatch_read_state_update(actor: actor) if broadcast_read_state
    refresh_communication_thread! if refresh_communication_thread
  end

  def refresh_communication_thread!
    Conversations::ReadStateTransaction.perform do
      conversation.class.find(conversation.id).refresh_communication_thread!
    end
  end
end
