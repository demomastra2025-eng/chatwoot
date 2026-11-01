class Conversations::FilterService < FilterService
  ATTRIBUTE_MODEL = 'conversation_attribute'.freeze

  def initialize(params, user, account)
    @account = account
    super(params, user)
  end

  def perform
    @conversations = selection_scope

    {
      conversations: conversations,
      count: include_meta? ? conversation_counts : {}
    }
  end

  # Returns the complete matching scope using the same advanced, CRM,
  # appointment, sidebar, and permission filters as the paginated list.
  def selection_scope
    validate_query_operator
    @base_filtered_conversations = query_builder(@filters['conversations'])
    @conversations = Conversations::ThreadRowDeduplicator.apply(
      apply_sidebar_scopes(
        apply_scheduling_appointment_context(
          apply_crm_deal_context(@base_filtered_conversations)
        )
      ),
      account: @account
    )
  end

  def base_relation
    conversations = @account.conversations.includes(
      :taggings, :inbox, { assignee: { avatar_attachment: [:blob] } }, { contact: { avatar_attachment: [:blob] } }, :team, :messages, :contact_inbox
    )

    Conversations::PermissionFilterService.new(
      conversations,
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

  def conversations
    @conversations.sort_on_last_activity_at.page(current_page)
  end

  private

  def include_meta?
    !@params.key?(:include_meta) || ActiveModel::Type::Boolean.new.cast(@params[:include_meta])
  end

  def conversation_counts
    mine_count, unassigned_count, all_count, = set_count_for_all_conversations
    assignee_counts = {
      mine_count: mine_count,
      assigned_count: all_count - unassigned_count,
      unassigned_count: unassigned_count,
      all_count: all_count
    }

    assignee_counts.merge(assignee_counts: assignee_counts, unread_counts: unread_counts)
  end

  def set_count_for_all_conversations
    counts = Conversations::AssigneeCountsAggregator.new(@conversations, user_id: @user.id).perform

    [counts[:mine_count], counts[:unassigned_count], counts[:all_count]]
  end

  def date_filter(current_filter, query_hash, filter_operator_value)
    return last_message_activity_filter(query_hash, filter_operator_value) if last_activity_filter?(query_hash)

    super
  end

  def last_activity_filter?(query_hash)
    query_hash['attribute_key'].to_s == 'last_activity_at'
  end

  def last_message_activity_filter(query_hash, filter_operator_value)
    <<~SQL.squish
      (#{last_public_message_activity_sql})::date #{filter_operator_value} #{query_hash[:query_operator]}
    SQL
  end

  def last_public_message_activity_sql
    <<~SQL.squish
      SELECT MAX(messages.created_at)
      FROM messages
      WHERE messages.conversation_id = conversations.id
        AND messages.account_id = conversations.account_id
        AND messages.private = FALSE
        AND messages.message_type != #{Message.message_types[:activity]}
    SQL
  end

  def apply_crm_deal_context(scope)
    Crm::DealDialogScopeBuilder.new(
      account: @account,
      pipeline_id: crm_pipeline_id,
      stage_id: crm_stage_id
    ).filter_conversations(scope)
  end

  def apply_scheduling_appointment_context(scope)
    Scheduling::AppointmentDialogScopeBuilder.new(
      account: @account,
      status: scheduling_appointment_status
    ).filter_conversations(scope)
  end

  def apply_sidebar_scopes(scope, include_unread: true)
    scope = scope.where.not(team_id: nil) if team_scope_any?
    scope = conversations_with_any_label(scope) if labels_scope_any?
    scope = apply_unread_filter(scope) if include_unread && unread_only?
    scope = apply_waiting_for_callback_filter(scope) if waiting_for_callback_only?
    scope = apply_calls_only_filter(scope) if calls_only?
    scope
  end

  def apply_waiting_for_callback_filter(scope)
    scope.where(
      "COALESCE(conversations.additional_attributes ->> 'waiting_for_callback', " \
      "conversations.custom_attributes ->> 'waiting_for_callback') = 'true'"
    )
  end

  def apply_calls_only_filter(scope)
    Conversations::CallsOnlyScope.apply(scope, account_id: @account&.id)
  end

  def apply_unread_filter(scope)
    scope.where(id: unread_conversation_scope(countable_conversation_scope(scope)).reselect(:id))
  end

  def unread_conversation_scope(scope)
    Conversations::UnreadScopeBuilder.new(scope: scope, account: @account).perform
  end

  # Only the team badge is shown in the dashboard, see Conversations::SidebarUnreadCountService.
  def unread_counts
    unread_scope = unread_conversation_scope(countable_conversation_scope(@conversations))

    Conversations::SidebarUnreadCountService.unread_counts_with(
      teams: normalize_counts(unread_scope.where.not(team_id: nil).group(:team_id).distinct.count('conversations.id'))
    )
  end

  def normalize_counts(counts)
    counts.each_with_object({}) do |(key, value), result|
      next if key.blank?

      result[key.to_s] = value
    end
  end

  def countable_conversation_scope(scope)
    scope.except(:includes, :eager_load, :preload)
  end

  def crm_pipeline_id
    @params[:crm_pipeline_id].presence || @params[:crmPipelineId].presence
  end

  def crm_stage_id
    @params[:crm_stage_id].presence || @params[:crmStageId].presence
  end

  def scheduling_appointment_status
    @params[:appointment_status].presence || @params[:appointmentStatus].presence
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

  def waiting_for_callback_only?
    ActiveModel::Type::Boolean.new.cast(
      @params[:waiting_for_callback].presence || @params[:waitingForCallback].presence
    )
  end

  def calls_only?
    ActiveModel::Type::Boolean.new.cast(
      @params[:calls_only].presence || @params[:callsOnly].presence
    )
  end

  # The label is on the conversation or on its contact (labels belong to the person).
  def conversations_with_any_label(scope)
    Labels::ConversationScope.with_any_label(scope)
  end

  # A label condition of the advanced filter also matches the labels of the conversation's contact, see FilterService#tag_filter_query.
  def match_contact_labels?
    true
  end
end
