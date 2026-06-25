class Conversations::FilterService < FilterService
  ATTRIBUTE_MODEL = 'conversation_attribute'.freeze

  def initialize(params, user, account)
    @account = account
    super(params, user)
  end

  def perform
    validate_query_operator
    @conversations = apply_sidebar_scopes(
      apply_crm_deal_context(query_builder(@filters['conversations']))
    )
    mine_count, unassigned_count, all_count, = set_count_for_all_conversations
    assigned_count = all_count - unassigned_count

    {
      conversations: conversations,
      count: {
        mine_count: mine_count,
        assigned_count: assigned_count,
        unassigned_count: unassigned_count,
        all_count: all_count
      }
    }
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

  def apply_sidebar_scopes(scope)
    scope = scope.where.not(team_id: nil) if team_scope_any?
    scope = conversations_with_any_label(scope) if labels_scope_any?
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
end
