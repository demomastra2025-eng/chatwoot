class Conversations::LastSeenUpdater
  pattr_initialize [:conversation!]

  def perform(last_seen_at:, update_assignee: false, refresh_communication_thread: true)
    return if last_seen_at.blank?

    updates = { agent_last_seen_at: last_seen_at }
    updates[:assignee_last_seen_at] = last_seen_at if update_assignee

    # rubocop:disable Rails/SkipsModelValidations
    conversation.update_columns(updates)
    # rubocop:enable Rails/SkipsModelValidations

    conversation.class.find(conversation.id).refresh_communication_thread! if refresh_communication_thread
  end
end
