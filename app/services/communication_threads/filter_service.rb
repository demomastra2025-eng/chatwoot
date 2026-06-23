# frozen_string_literal: true

class CommunicationThreads::FilterService < FilterService
  ATTRIBUTE_MODEL = 'conversation_attribute'
  DEFAULT_SORT = 'last_activity_at_desc'

  def initialize(params, user, account)
    @account = account
    super(params, user)
  end

  def perform
    validate_query_operator
    matching_conversations = apply_conversation_scopes(query_builder(@filters['conversations']))
    @communication_threads = apply_thread_scopes(
      apply_crm_deal_context(thread_scope_for(matching_conversations))
    )

    {
      communication_threads: communication_threads,
      count: thread_counts
    }
  end

  def base_relation
    Conversations::PermissionFilterService.new(
      @account.conversations,
      @user,
      @account
    ).perform
  end

  def current_page
    @params[:page] || 1
  end

  def filter_config
    {
      entity: 'Conversation',
      table_name: 'conversations'
    }
  end

  def communication_threads
    @communication_threads
      .includes(:contact, :assignee, :team)
      .order(Arel.sql(sort_clause))
      .page(current_page)
      .per(CommunicationThreadFinder::RESULTS_PER_PAGE)
  end

  private

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

  def apply_conversation_scopes(scope)
    return conversations_with_any_label(scope) if labels_scope_any?

    scope
  end

  def apply_thread_scopes(scope)
    return scope.where.not(team_id: nil) if team_scope_any?

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

  def conversations_with_any_label(scope)
    scope.joins(
      'INNER JOIN taggings conversation_any_label_taggings ' \
      'ON conversation_any_label_taggings.taggable_id = conversations.id ' \
      "AND conversation_any_label_taggings.taggable_type = 'Conversation' " \
      "AND conversation_any_label_taggings.context = 'labels'"
    ).distinct
  end

  def sort_clause
    CommunicationThreadFinder::SORT_OPTIONS.fetch(@params[:sort_by].presence || DEFAULT_SORT)
  end

  def thread_counts
    assignee_counts = assignee_counts_for(@communication_threads)
    {
      mine_count: assignee_counts[:mine_count],
      assigned_count: assignee_counts[:assigned_count],
      unassigned_count: assignee_counts[:unassigned_count],
      all_count: assignee_counts[:all_count],
      mine_unread_count: unread_thread_count(@communication_threads.where(assignee_id: @user.id)),
      assigned_unread_count: unread_thread_count(@communication_threads.where.not(assignee_id: nil)),
      unassigned_unread_count: unread_thread_count(@communication_threads.where(assignee_id: nil)),
      all_unread_count: unread_thread_count(@communication_threads),
      assignee_counts: assignee_counts
    }
  end

  def assignee_counts_for(scope)
    mine_count = scope.where(assignee_id: @user.id).count
    unassigned_count = scope.where(assignee_id: nil).count
    all_count = scope.count

    {
      mine_count: mine_count,
      assigned_count: all_count - unassigned_count,
      unassigned_count: unassigned_count,
      all_count: all_count
    }
  end

  def unread_thread_count(scope)
    scope.where('communication_threads.unread_count > 0').count
  end
end
