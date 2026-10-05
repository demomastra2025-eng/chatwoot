# frozen_string_literal: true

class CommunicationThreads::FilterService < FilterService
  ATTRIBUTE_MODEL = 'conversation_attribute'
  DEFAULT_SORT = 'last_activity_at_desc'

  def initialize(params, user, account)
    @account = account
    super(params, user)
  end

  def perform
    set_up

    {
      communication_threads: meta_only? ? CommunicationThread.none : communication_threads,
      count: include_meta? ? thread_counts : {}
    }
  end

  def perform_sidebar_unread_counts
    set_up
    unread_counts
  end

  def base_relation
    Conversations::PermissionFilterService.new(
      @account.conversations,
      @user,
      @account
    ).perform
  end

  private

  def set_up
    validate_query_operator
    validate_sort_by!
    @base_matching_conversations = apply_conversation_scopes(query_builder(@filters['conversations']))
    @base_thread_scope = thread_scope_for(@base_matching_conversations)
    @communication_threads = apply_thread_scopes(
      apply_scheduling_appointment_context(
        apply_crm_deal_context(@base_thread_scope)
      )
    )
  end

  def current_page
    @params[:page] || 1
  end

  def include_meta?
    !@params.key?(:include_meta) || ActiveModel::Type::Boolean.new.cast(@params[:include_meta])
  end

  def meta_only?
    ActiveModel::Type::Boolean.new.cast(@params[:meta_only])
  end

  def filter_config
    {
      entity: 'Conversation',
      table_name: 'conversations'
    }
  end

  def communication_threads
    relation = @communication_threads
    relation = with_last_message_activity_sort(relation) if message_sort?
    relation = with_waiting_since_sort(relation) if waiting_sort?

    relation
      .includes(thread_list_preloads)
      .order(Arel.sql(sort_clause))
      .page(current_page)
      .per(CommunicationThreadFinder::RESULTS_PER_PAGE)
  end

  def validate_sort_by!
    return if CommunicationThreadFinder::SORT_OPTIONS.key?(sort_key)

    raise CommunicationThreadFinder::InvalidParameter, "Invalid communication thread sort_by: #{sort_key}"
  end

  def thread_scope_for(conversation_scope)
    CommunicationThread
      .where(account_id: @account.id)
      .joins(:communication_thread_conversations)
      .where(communication_thread_conversations: { conversation_id: conversation_scope.select(:id) })
      .distinct
  end

  def apply_crm_deal_context(scope)
    Crm::DealDialogScopeBuilder.new(
      account: @account,
      pipeline_id: crm_pipeline_id,
      stage_id: crm_stage_id
    ).filter_communication_threads(scope)
  end

  def apply_scheduling_appointment_context(scope)
    Scheduling::AppointmentDialogScopeBuilder.new(
      account: @account,
      status: scheduling_appointment_status
    ).filter_communication_threads(scope)
  end

  def apply_conversation_scopes(scope)
    return conversations_with_any_label(scope) if labels_scope_any?

    scope
  end

  def apply_thread_scopes(scope, include_unread: true)
    scope = scope.where.not(team_id: nil) if team_scope_any?
    scope = unread_thread_scope(scope) if include_unread && unread_only?
    scope
  end

  def crm_pipeline_id
    @params[:crm_pipeline_id].presence || @params[:crmPipelineId].presence
  end

  def crm_stage_id
    @params[:crm_stage_id].presence || @params[:crmStageId].presence
  end

  def labels_scope_any?
    (@params[:labels_scope].presence || @params[:labelsScope].presence).to_s == 'any'
  end

  def team_scope_any?
    (@params[:team_scope].presence || @params[:teamScope].presence).to_s == 'any'
  end

  def unread_only?
    ActiveModel::Type::Boolean.new.cast(
      @params[:unread].presence || @params[:unread_only].presence || @params[:unreadOnly].presence
    )
  end

  def conversations_with_any_label(scope)
    scope.joins(
      'INNER JOIN taggings conversation_any_label_taggings ' \
      'ON conversation_any_label_taggings.taggable_id = conversations.id ' \
      "AND conversation_any_label_taggings.taggable_type = 'Conversation' " \
      "AND conversation_any_label_taggings.context = 'labels'"
    ).distinct
  end

  def sort_clause
    CommunicationThreadFinder::SORT_OPTIONS.fetch(sort_key)
  end

  def sort_key
    @params[:sort_by].presence || DEFAULT_SORT
  end

  def message_sort?
    CommunicationThreadFinder.message_sort?(sort_key)
  end

  def waiting_sort?
    CommunicationThreadFinder::WAITING_SORT_KEYS.include?(sort_key.to_s)
  end

  def with_last_message_activity_sort(relation)
    CommunicationThreadFinder.with_last_message_activity_sort(relation, base_relation)
  end

  def with_waiting_since_sort(relation)
    sort_sql = CommunicationThreadFinder.waiting_since_sort_sql(base_relation)

    relation.select(
      Arel.sql("communication_threads.*, (#{sort_sql}) AS thread_waiting_since_sort_at")
    )
  end

  def thread_list_preloads
    [
      {
        contact: [
          { contact_channel_profiles: { avatar_attachment: :blob } },
          { avatar_attachment: :blob },
          { owner: [:account_users, { avatar_attachment: :blob }] }
        ]
      },
      { assignee: [:account_users, { avatar_attachment: :blob }] },
      :team
    ]
  end

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

  def scheduling_appointment_status
    @params[:appointment_status].presence || @params[:appointmentStatus].presence
  end
end
