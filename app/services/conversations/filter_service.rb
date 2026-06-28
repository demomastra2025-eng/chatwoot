class Conversations::FilterService < FilterService
  ATTRIBUTE_MODEL = 'conversation_attribute'.freeze

  def initialize(params, user, account)
    @account = account
    super(params, user)
  end

  def perform
    validate_query_operator
    @base_filtered_conversations = query_builder(@filters['conversations'])
    @conversations = apply_sidebar_scopes(
      apply_scheduling_appointment_context(
        apply_crm_deal_context(@base_filtered_conversations)
      )
    )
    mine_count, unassigned_count, all_count, = set_count_for_all_conversations
    assigned_count = all_count - unassigned_count
    assignee_counts = {
      mine_count: mine_count,
      assigned_count: assigned_count,
      unassigned_count: unassigned_count,
      all_count: all_count
    }

    {
      conversations: conversations,
      count: assignee_counts.merge(
        assignee_counts: assignee_counts,
        unread_counts: unread_counts
      )
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
    scope
  end

  def apply_unread_filter(scope)
    scope.where(id: unread_conversation_scope(countable_conversation_scope(scope)).reselect(:id))
  end

  def unread_conversation_scope(scope)
    scope.joins(:messages)
         .where(messages: unread_message_filters)
         .where(
           'messages.created_at > COALESCE(conversations.agent_last_seen_at, ?)',
           Time.zone.at(0)
         )
  end

  def unread_message_filters
    {
      account_id: @account.id,
      message_type: Message.message_types[:incoming],
      private: false
    }
  end

  def unread_counts
    base_scope = countable_conversation_scope(@conversations)
    unread_scope = unread_conversation_scope(base_scope)
    crm_count_scope = unread_conversation_scope(crm_unread_count_base_scope)
    appointment_count_scope = unread_conversation_scope(appointment_unread_count_base_scope)

    {
      all: unread_dialog_count(base_scope),
      statuses: normalize_enum_counts(unread_scope.group(:status).distinct.count('conversations.id'), Conversation.statuses),
      inboxes: normalize_counts(unread_scope.group(:inbox_id).distinct.count('conversations.id')),
      teams: normalize_counts(unread_scope.where.not(team_id: nil).group(:team_id).distinct.count('conversations.id')),
      labels: normalize_counts(label_counts(unread_scope)),
      pipelines: crm_unread_count_service(crm_count_scope).conversation_pipeline_counts,
      stages: crm_unread_count_service(crm_count_scope).conversation_stage_counts,
      appointment_statuses: scheduling_appointment_count_service(appointment_count_scope).conversation_status_counts
    }
  end

  def unread_dialog_count(scope)
    unread_conversation_scope(scope).distinct.count('conversations.id')
  end

  def label_counts(scope)
    scope.joins(
      'INNER JOIN taggings ON taggings.taggable_id = conversations.id ' \
      "AND taggings.taggable_type = 'Conversation' " \
      "AND taggings.context = 'labels'"
    ).joins('INNER JOIN tags ON tags.id = taggings.tag_id')
         .group('tags.name')
         .distinct
         .count('conversations.id')
  end

  def normalize_counts(counts)
    counts.each_with_object({}) do |(key, value), result|
      next if key.blank?

      result[key.to_s] = value
    end
  end

  def normalize_enum_counts(counts, enum_mapping)
    counts.each_with_object({}) do |(key, value), result|
      enum_key = enum_mapping.key(key) || key.to_s
      next if enum_key.blank?

      result[enum_key] = value
    end
  end

  def crm_unread_count_service(scope)
    Crm::DealDialogUnreadCountService.new(account: @account, conversation_scope: scope)
  end

  def scheduling_appointment_count_service(scope)
    Scheduling::AppointmentDialogCountService.new(account: @account, conversation_scope: scope)
  end

  def countable_conversation_scope(scope)
    scope.except(:includes, :eager_load, :preload)
  end

  def crm_unread_count_base_scope
    countable_conversation_scope(
      apply_sidebar_scopes(
        apply_scheduling_appointment_context(@base_filtered_conversations),
        include_unread: false
      )
    )
  end

  def appointment_unread_count_base_scope
    countable_conversation_scope(
      apply_sidebar_scopes(
        apply_crm_deal_context(@base_filtered_conversations),
        include_unread: false
      )
    )
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

  def conversations_with_any_label(scope)
    scope.joins(
      'INNER JOIN taggings conversation_any_label_taggings ' \
      'ON conversation_any_label_taggings.taggable_id = conversations.id ' \
      "AND conversation_any_label_taggings.taggable_type = 'Conversation' " \
      "AND conversation_any_label_taggings.context = 'labels'"
    ).distinct
  end
end
