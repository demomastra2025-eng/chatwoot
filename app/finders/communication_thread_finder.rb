class CommunicationThreadFinder # rubocop:disable Metrics/ClassLength
  class InvalidParameter < StandardError; end

  attr_reader :current_user, :current_account, :params

  DEFAULT_STATUS = 'open'.freeze
  RESULTS_PER_PAGE = ENV.fetch('CONVERSATION_RESULTS_PER_PAGE', '25').to_i
  THREAD_RELATION_FILTERS = {
    include_status: true,
    include_inbox: true,
    include_assignee: false,
    include_team: true,
    include_labels: true,
    include_crm_deal_context: true,
    include_scheduling_appointment_context: true,
    include_unread: true
  }.freeze
  SORT_OPTIONS = {
    'last_activity_at_asc' => 'last_message_activity_sort_at ASC NULLS LAST, communication_threads.id ASC',
    'last_activity_at_desc' => 'last_message_activity_sort_at DESC NULLS LAST, communication_threads.id DESC',
    'last_event_activity_at_asc' => 'communication_threads.last_activity_at ASC NULLS LAST, communication_threads.id ASC',
    'last_event_activity_at_desc' => 'communication_threads.last_activity_at DESC NULLS LAST, communication_threads.id DESC',
    'latest' => 'last_message_activity_sort_at DESC NULLS LAST, communication_threads.id DESC',
    'created_at_asc' => 'communication_threads.created_at ASC, communication_threads.id ASC',
    'created_at_desc' => 'communication_threads.created_at DESC, communication_threads.id DESC',
    'priority_asc' => [
      'communication_threads.priority ASC NULLS LAST',
      'communication_threads.last_activity_at DESC NULLS LAST',
      'communication_threads.id DESC'
    ].join(', '),
    'priority_desc' => [
      'communication_threads.priority DESC NULLS LAST',
      'communication_threads.last_activity_at DESC NULLS LAST',
      'communication_threads.id DESC'
    ].join(', ')
  }.with_indifferent_access
  MESSAGE_SORT_KEYS = %w[last_activity_at_asc last_activity_at_desc latest].freeze
  STATUS_COUNT_KEYS = %w[open pending snoozed resolved].freeze

  def self.message_sort?(sort_key)
    MESSAGE_SORT_KEYS.include?(sort_key.to_s)
  end

  def self.last_message_activity_sort_sql(conversation_scope)
    <<~SQL.squish
      COALESCE(
        (#{last_message_activity_subquery_sql(conversation_scope)}),
        communication_threads.created_at
      )
    SQL
  end

  def self.last_message_activity_subquery_sql(conversation_scope)
    activity_message_type = Message.message_types[:activity]
    conversation_ids_sql = conversation_scope.reselect('conversations.id').to_sql

    <<~SQL.squish
      SELECT MAX(messages.created_at)
      FROM messages
      INNER JOIN communication_thread_conversations sort_thread_links
        ON sort_thread_links.conversation_id = messages.conversation_id
       AND sort_thread_links.communication_thread_id = communication_threads.id
      INNER JOIN (#{conversation_ids_sql}) sort_accessible_conversations
        ON sort_accessible_conversations.id = sort_thread_links.conversation_id
      WHERE sort_thread_links.account_id = communication_threads.account_id
        AND messages.account_id = communication_threads.account_id
        AND messages.private = FALSE
        AND messages.message_type != #{activity_message_type}
    SQL
  end

  def initialize(current_user, params)
    @current_user = current_user
    @current_account = current_user.account
    @params = params
  end

  def perform
    set_up
    count = thread_counts
    filter_by_assignee_type

    {
      communication_threads: communication_threads,
      count: count
    }
  end

  def perform_meta_only
    set_up

    { count: thread_counts }
  end

  private

  def set_up
    validate_params!
    find_accessible_threads
    filter_by_status
    filter_by_inbox
    filter_by_team
    filter_by_labels
    filter_by_crm_deal_context
    filter_by_scheduling_appointment_context
    filter_by_unread
  end

  def validate_params!
    validate_status!
    validate_sort_by!
  end

  def validate_status!
    status = params[:status]
    return if status.blank? || status == 'all'
    return if CommunicationThread.statuses.key?(status)

    raise InvalidParameter, "Invalid communication thread status: #{status}"
  end

  def validate_sort_by!
    sort_by = params[:sort_by]
    return if sort_by.blank? || SORT_OPTIONS.key?(sort_by)

    raise InvalidParameter, "Invalid communication thread sort_by: #{sort_by}"
  end

  def find_accessible_threads
    @communication_threads = CommunicationThread
                             .where(account_id: current_account.id)
                             .joins(:communication_thread_conversations)
                             .where(communication_thread_conversations: { conversation_id: accessible_conversations.select(:id) })
                             .distinct
  end

  def filter_by_status
    return if params[:status] == 'all'

    status = params[:status].presence || DEFAULT_STATUS
    @communication_threads = @communication_threads.where(
      'communication_threads.status = :thread_status OR communication_thread_conversations.conversation_id IN (:matching_conversation_ids)',
      thread_status: CommunicationThread.statuses.fetch(status),
      matching_conversation_ids: accessible_conversations
        .where(status: Conversation.statuses.fetch(status))
        .select(:id)
    )
  end

  def filter_by_inbox
    return if params[:inbox_id].blank?

    @communication_threads = @communication_threads.where(communication_thread_conversations: { inbox_id: params[:inbox_id] })
  end

  def filter_by_team
    if params[:team_id].present?
      @communication_threads = @communication_threads.where(team_id: params[:team_id])
      return
    end

    @communication_threads = @communication_threads.where.not(team_id: nil) if team_scope_any?
  end

  def filter_by_labels
    return if params[:labels].blank? && !labels_scope_any?

    @communication_threads = @communication_threads.where(
      communication_thread_conversations: { conversation_id: labeled_conversation_ids }
    )
  end

  def filter_by_crm_deal_context
    @communication_threads = current_crm_deal_dialog_scope.filter_communication_threads(@communication_threads)
  end

  def filter_by_scheduling_appointment_context
    @communication_threads = current_scheduling_appointment_dialog_scope.filter_communication_threads(@communication_threads)
  end

  def filter_by_unread
    @communication_threads = apply_unread_filter(@communication_threads)
  end

  def filter_by_assignee_type
    case params[:assignee_type]
    when 'me'
      @communication_threads = @communication_threads.where(assignee_id: current_user.id)
    when 'unassigned'
      @communication_threads = @communication_threads.where(assignee_id: nil)
    when 'assigned'
      @communication_threads = @communication_threads.where.not(assignee_id: nil)
    end
  end

  def set_count_for_all_threads
    counts = assignee_counts_for(@communication_threads)

    [
      counts[:mine_count],
      counts[:unassigned_count],
      counts[:all_count],
      unread_thread_count(@communication_threads.where(assignee_id: current_user.id)),
      unread_thread_count(@communication_threads.where(assignee_id: nil)),
      unread_thread_count(@communication_threads)
    ]
  end

  def thread_counts
    mine_count, unassigned_count, all_count, mine_unread_count, unassigned_unread_count, all_unread_count =
      set_count_for_all_threads

    {
      mine_count: mine_count,
      assigned_count: all_count - unassigned_count,
      unassigned_count: unassigned_count,
      all_count: all_count,
      mine_unread_count: mine_unread_count,
      assigned_unread_count: all_unread_count - unassigned_unread_count,
      unassigned_unread_count: unassigned_unread_count,
      all_unread_count: all_unread_count,
      assignee_counts: assignee_counts_for(base_thread_scope),
      unread_counts: unread_counts
    }
  end

  def assignee_counts_for(scope)
    mine_count = scope.where(assignee_id: current_user.id).count
    unassigned_count = scope.where(assignee_id: nil).count
    all_count = scope.count

    {
      mine_count: mine_count,
      assigned_count: all_count - unassigned_count,
      unassigned_count: unassigned_count,
      all_count: all_count
    }
  end

  def unread_counts
    channel_counts = channel_unread_counts

    {
      all: channel_counts[:all],
      statuses: status_unread_counts,
      inboxes: channel_counts[:inboxes],
      teams: team_unread_counts,
      labels: label_unread_counts,
      pipelines: pipeline_unread_counts,
      stages: stage_unread_counts,
      appointment_statuses: appointment_status_unread_counts
    }
  end

  def status_unread_counts
    scope = scoped_thread_relation(include_status: false, include_assignee: true, include_unread: false)

    STATUS_COUNT_KEYS.index_with do |status|
      unread_thread_count(apply_status_filter(scope, status))
    end
  end

  def channel_unread_counts
    scope = scoped_thread_relation(include_inbox: false, include_assignee: true, include_unread: false)
    unread_scope = unread_thread_scope(scope)
    thread_ids = unread_scope.select(:id)

    {
      all: unread_scope.count,
      inboxes: CommunicationThreadConversation
        .where(
          account_id: current_account.id,
          communication_thread_id: thread_ids,
          conversation_id: accessible_conversations.select(:id)
        )
        .group(:inbox_id)
        .distinct
        .count(:communication_thread_id)
        .transform_keys(&:to_s)
    }
  end

  def team_unread_counts
    scope = scoped_thread_relation(include_team: false, include_assignee: true, include_unread: false)

    normalize_counts(unread_thread_scope(scope).where.not(team_id: nil).group(:team_id).count)
  end

  def label_unread_counts
    scope = scoped_thread_relation(include_labels: false, include_assignee: true, include_unread: false)
    thread_ids = unread_thread_scope(scope).select(:id)

    normalize_counts(
      CommunicationThreadConversation
        .where(
          account_id: current_account.id,
          communication_thread_id: thread_ids,
          conversation_id: accessible_conversations.select(:id)
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

  def pipeline_unread_counts
    crm_unread_count_service.communication_thread_pipeline_counts
  end

  def stage_unread_counts
    crm_unread_count_service.communication_thread_stage_counts
  end

  def appointment_status_unread_counts
    scheduling_appointment_count_service.communication_thread_status_counts
  end

  def unread_thread_scope(scope)
    CommunicationThread
      .where(id: scope.except(:order).select(:id))
      .where('communication_threads.unread_count > 0')
  end

  def normalize_counts(counts)
    counts.each_with_object({}) do |(key, value), result|
      next if key.blank?

      result[key.to_s] = value
    end
  end

  def scoped_thread_relation(filters = {})
    filters = THREAD_RELATION_FILTERS.merge(filters)

    [
      [:include_status, method(:apply_status_filter)],
      [:include_inbox, method(:apply_inbox_filter)],
      [:include_team, method(:apply_team_filter)],
      [:include_labels, method(:apply_labels_filter)],
      [:include_crm_deal_context, method(:apply_crm_deal_context_filter)],
      [:include_scheduling_appointment_context, method(:apply_scheduling_appointment_context_filter)],
      [:include_unread, method(:apply_unread_filter)],
      [:include_assignee, method(:apply_assignee_filter)]
    ].reduce(base_thread_scope) do |scope, (filter_key, filter_method)|
      filters[filter_key] ? filter_method.call(scope) : scope
    end
  end

  def base_thread_scope
    CommunicationThread
      .where(account_id: current_account.id)
      .where(id: linked_thread_ids)
  end

  def linked_thread_ids(conversation_ids: accessible_conversations.select(:id), inbox_id: nil)
    relation = CommunicationThreadConversation
               .where(account_id: current_account.id)
               .where(conversation_id: conversation_ids)
    relation = relation.where(inbox_id: inbox_id) if inbox_id.present?

    relation.select(:communication_thread_id)
  end

  def apply_status_filter(scope, status = nil)
    selected_status = status || params[:status]
    return scope if selected_status == 'all'

    status_value = selected_status.presence || DEFAULT_STATUS
    matching_thread_ids = linked_thread_ids(
      conversation_ids: accessible_conversations
        .where(status: Conversation.statuses.fetch(status_value))
        .select(:id)
    )

    scope.where(
      'communication_threads.status = :thread_status OR communication_threads.id IN (:matching_thread_ids)',
      thread_status: CommunicationThread.statuses.fetch(status_value),
      matching_thread_ids: matching_thread_ids
    )
  end

  def apply_inbox_filter(scope)
    return scope if params[:inbox_id].blank?

    scope.where(id: linked_thread_ids(inbox_id: params[:inbox_id]))
  end

  def apply_team_filter(scope)
    return scope.where(team_id: params[:team_id]) if params[:team_id].present?
    return scope.where.not(team_id: nil) if team_scope_any?

    scope
  end

  def apply_labels_filter(scope)
    return scope if params[:labels].blank? && !labels_scope_any?

    scope.where(id: linked_thread_ids(conversation_ids: labeled_conversation_ids))
  end

  def apply_crm_deal_context_filter(scope)
    current_crm_deal_dialog_scope.filter_communication_threads(scope)
  end

  def apply_scheduling_appointment_context_filter(scope)
    current_scheduling_appointment_dialog_scope.filter_communication_threads(scope)
  end

  def apply_unread_filter(scope)
    return scope unless unread_only?

    unread_thread_scope(scope)
  end

  def apply_assignee_filter(scope)
    case params[:assignee_type]
    when 'me'
      scope.where(assignee_id: current_user.id)
    when 'unassigned'
      scope.where(assignee_id: nil)
    when 'assigned'
      scope.where.not(assignee_id: nil)
    else
      scope
    end
  end

  def unread_thread_count(scope)
    unread_thread_scope(scope).count
  end

  def communication_threads
    relation = @communication_threads
    relation = with_last_message_activity_sort(relation) if message_sort?

    relation
      .includes(:contact, :assignee, :team)
      .order(Arel.sql(sort_clause))
      .page(params[:page] || 1)
      .per(RESULTS_PER_PAGE)
  end

  def sort_clause
    SORT_OPTIONS[sort_key]
  end

  def sort_key
    params[:sort_by].presence || 'last_activity_at_desc'
  end

  def message_sort?
    self.class.message_sort?(sort_key)
  end

  def with_last_message_activity_sort(relation)
    sort_sql = self.class.last_message_activity_sort_sql(accessible_conversations)

    relation
      .select(
        Arel.sql("communication_threads.*, #{sort_sql} AS last_message_activity_sort_at")
      )
  end

  def accessible_conversations
    @accessible_conversations ||= Conversations::PermissionFilterService.new(
      current_account.conversations,
      current_user,
      current_account
    ).perform
  end

  def crm_pipeline_id
    params[:crm_pipeline_id].presence || params[:crmPipelineId].presence
  end

  def crm_stage_id
    params[:crm_stage_id].presence || params[:crmStageId].presence
  end

  def scheduling_appointment_status
    params[:appointment_status].presence || params[:appointmentStatus].presence
  end

  def labels_scope_any?
    (params[:labels_scope].presence || params[:labelsScope].presence).to_s == 'any'
  end

  def team_scope_any?
    (params[:team_scope].presence || params[:teamScope].presence).to_s == 'any'
  end

  def unread_only?
    ActiveModel::Type::Boolean.new.cast(
      params[:unread].presence || params[:unread_only].presence || params[:unreadOnly].presence
    )
  end

  def labeled_conversation_ids
    return accessible_conversations.tagged_with(params[:labels], any: true).reselect(:id) if params[:labels].present?

    conversations_with_any_label(accessible_conversations).reselect(:id)
  end

  def conversations_with_any_label(scope)
    scope.joins(
      'INNER JOIN taggings conversation_any_label_taggings ' \
      'ON conversation_any_label_taggings.taggable_id = conversations.id ' \
      "AND conversation_any_label_taggings.taggable_type = 'Conversation' " \
      "AND conversation_any_label_taggings.context = 'labels'"
    ).distinct
  end

  def current_crm_deal_dialog_scope
    crm_deal_dialog_scope(pipeline_id: crm_pipeline_id, stage_id: crm_stage_id)
  end

  def crm_deal_dialog_scope(pipeline_id: nil, stage_id: nil)
    Crm::DealDialogScopeBuilder.new(
      account: current_account,
      pipeline_id: pipeline_id,
      stage_id: stage_id
    )
  end

  def crm_unread_count_service
    @crm_unread_count_service ||= Crm::DealDialogUnreadCountService.new(
      account: current_account,
      communication_thread_scope: crm_unread_thread_scope
    )
  end

  def crm_unread_thread_scope
    @crm_unread_thread_scope ||= unread_thread_scope(
      scoped_thread_relation(include_crm_deal_context: false, include_assignee: true, include_unread: false)
    )
  end

  def current_scheduling_appointment_dialog_scope
    scheduling_appointment_dialog_scope(status: scheduling_appointment_status)
  end

  def scheduling_appointment_dialog_scope(status: nil)
    Scheduling::AppointmentDialogScopeBuilder.new(
      account: current_account,
      status: status
    )
  end

  def scheduling_appointment_count_service
    @scheduling_appointment_count_service ||= Scheduling::AppointmentDialogCountService.new(
      account: current_account,
      communication_thread_scope: scheduling_appointment_count_thread_scope
    )
  end

  def scheduling_appointment_count_thread_scope
    @scheduling_appointment_count_thread_scope ||= unread_thread_scope(
      scoped_thread_relation(
        include_scheduling_appointment_context: false,
        include_assignee: true,
        include_unread: false
      )
    )
  end
end
