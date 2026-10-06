module CommunicationThreads::FilterService::Counters
  private

  def thread_counts
    assignee_counts = assignee_counts_for(@communication_threads)
    unread_assignee_counts = assignee_counts_for(unread_thread_scope(@communication_threads))
    {
      mine_count: assignee_counts[:mine_count],
      assigned_count: assignee_counts[:assigned_count],
      unassigned_count: assignee_counts[:unassigned_count],
      all_count: assignee_counts[:all_count],
      mine_unread_count: unread_assignee_counts[:mine_count],
      assigned_unread_count: unread_assignee_counts[:assigned_count],
      unassigned_unread_count: unread_assignee_counts[:unassigned_count],
      all_unread_count: unread_assignee_counts[:all_count],
      assignee_counts: assignee_counts,
      unread_counts: unread_counts
    }
  end

  # Only the team badge is shown in the dashboard, see Conversations::SidebarUnreadCountService.
  def unread_counts
    unread_scope = unread_thread_scope(@communication_threads)

    Conversations::SidebarUnreadCountService.unread_counts_with(
      teams: normalize_counts(unread_scope.where.not(team_id: nil).group(:team_id).count)
    )
  end

  def assignee_counts_for(scope)
    counts = Conversations::AssigneeCountsAggregator.new(scope, user_id: @user.id).perform

    {
      mine_count: counts[:mine_count],
      assigned_count: counts[:all_count] - counts[:unassigned_count],
      unassigned_count: counts[:unassigned_count],
      all_count: counts[:all_count]
    }
  end

  def unread_thread_scope(scope)
    unread_conversation_ids = Conversations::UnreadScopeBuilder.new(
      scope: base_relation,
      account: @account
    ).perform.select(:id)
    unread_thread_ids = CommunicationThreadConversation
                        .where(account_id: @account.id, conversation_id: unread_conversation_ids)
                        .select(:communication_thread_id)
    scope.where(id: unread_thread_ids)
  end

  def normalize_counts(counts)
    counts.each_with_object({}) do |(key, value), result|
      next if key.blank?

      result[key.to_s] = value
    end
  end
end
