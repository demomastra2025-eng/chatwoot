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
    {
      mine_count: assignee_counts[:mine_count],
      assigned_count: assignee_counts[:assigned_count],
      unassigned_count: assignee_counts[:unassigned_count],
      all_count: assignee_counts[:all_count],
      mine_unread_count: unread_thread_count(@communication_threads.where(assignee_id: @user.id)),
      assigned_unread_count: unread_thread_count(@communication_threads.where.not(assignee_id: nil)),
      unassigned_unread_count: unread_thread_count(@communication_threads.where(assignee_id: nil)),
      all_unread_count: unread_thread_count(@communication_threads),
      assignee_counts: assignee_counts,
      unread_counts: unread_counts
    }
  end

  def unread_counts
    unread_scope = unread_thread_scope(@communication_threads)
    crm_count_scope = unread_thread_scope(crm_unread_count_base_scope)
    appointment_count_scope = unread_thread_scope(appointment_unread_count_base_scope)

    {
      all: unread_scope.count,
      statuses: normalize_enum_counts(unread_scope.group(:status).count, CommunicationThread.statuses),
      inboxes: channel_unread_counts(unread_scope),
      teams: normalize_counts(unread_scope.where.not(team_id: nil).group(:team_id).count),
      labels: label_unread_counts(unread_scope),
      pipelines: crm_unread_count_service(crm_count_scope).communication_thread_pipeline_counts,
      stages: crm_unread_count_service(crm_count_scope).communication_thread_stage_counts,
      appointment_statuses: scheduling_appointment_count_service(appointment_count_scope).communication_thread_status_counts
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
    unread_thread_scope(scope).count
  end

  def unread_thread_scope(scope)
    scope.where('communication_threads.unread_count > 0')
  end

  def channel_unread_counts(scope)
    CommunicationThreadConversation
      .where(
        account_id: @account.id,
        communication_thread_id: scope.select(:id),
        conversation_id: base_relation.select(:id)
      )
      .group(:inbox_id)
      .distinct
      .count(:communication_thread_id)
      .transform_keys(&:to_s)
  end

  def label_unread_counts(scope)
    normalize_counts(
      CommunicationThreadConversation
        .where(
          account_id: @account.id,
          communication_thread_id: scope.select(:id),
          conversation_id: base_relation.select(:id)
        )
        .joins(
          'INNER JOIN taggings ON taggings.taggable_id = communication_thread_conversations.conversation_id ' \
          "AND taggings.taggable_type = 'Conversation' " \
          "AND taggings.context = 'labels'"
        )
        .joins('INNER JOIN tags ON tags.id = taggings.tag_id')
        .group('tags.name')
        .distinct
        .count(:communication_thread_id)
    )
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
    Crm::DealDialogUnreadCountService.new(account: @account, communication_thread_scope: scope)
  end

  def scheduling_appointment_count_service(scope)
    Scheduling::AppointmentDialogCountService.new(account: @account, communication_thread_scope: scope)
  end

  def crm_unread_count_base_scope
    apply_thread_scopes(
      apply_scheduling_appointment_context(@base_thread_scope),
      include_unread: false
    )
  end

  def appointment_unread_count_base_scope
    apply_thread_scopes(
      apply_crm_deal_context(@base_thread_scope),
      include_unread: false
    )
  end

  def scheduling_appointment_status
    @params[:appointment_status].presence || @params[:appointmentStatus].presence
  end
end
