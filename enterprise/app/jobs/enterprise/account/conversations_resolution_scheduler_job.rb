module Enterprise::Account::ConversationsResolutionSchedulerJob
  def perform
    super

    resolve_captain_conversations
  end

  private

  def resolve_captain_conversations
    CaptainInbox.all.find_each(batch_size: 100) do |captain_inbox|
      inbox = captain_inbox.inbox

      if inbox.blank?
        Rails.logger.warn("[CaptainInbox] skipping orphaned captain inbox id=#{captain_inbox.id}")
        next
      end

      next if inbox.email?
      next unless inbox.captain_active?
      next unless captain_inbox.captain_assistant&.active?
      next if inbox.account.auto_resolve_after.blank?
      next if inbox.account.captain_auto_resolve_disabled?

      Captain::InboxPendingConversationsResolutionJob.perform_later(
        inbox
      )
    end
  end
end
