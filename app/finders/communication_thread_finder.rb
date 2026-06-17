class CommunicationThreadFinder # rubocop:disable Metrics/ClassLength
  class InvalidParameter < StandardError; end

  attr_reader :current_user, :current_account, :params

  DEFAULT_STATUS = 'open'.freeze
  RESULTS_PER_PAGE = ENV.fetch('CONVERSATION_RESULTS_PER_PAGE', '25').to_i
  SORT_OPTIONS = {
    'last_activity_at_asc' => 'communication_threads.last_activity_at ASC NULLS LAST, communication_threads.id ASC',
    'last_activity_at_desc' => 'communication_threads.last_activity_at DESC NULLS LAST, communication_threads.id DESC',
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
  STATUS_COUNT_KEYS = %w[open pending snoozed resolved].freeze

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
    return if params[:team_id].blank?

    @communication_threads = @communication_threads.where(team_id: params[:team_id])
  end

  def filter_by_labels
    return if params[:labels].blank?

    labeled_conversation_ids = accessible_conversations.tagged_with(params[:labels], any: true).reselect(:id)
    @communication_threads = @communication_threads.where(
      communication_thread_conversations: { conversation_id: labeled_conversation_ids }
    )
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
      labels: label_unread_counts
    }
  end

  def status_unread_counts
    scope = scoped_thread_relation(include_status: false, include_assignee: true)

    STATUS_COUNT_KEYS.index_with do |status|
      unread_thread_count(apply_status_filter(scope, status))
    end
  end

  def channel_unread_counts
    scope = scoped_thread_relation(include_inbox: false, include_assignee: true)
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
    scope = scoped_thread_relation(include_team: false, include_assignee: true)

    normalize_counts(unread_thread_scope(scope).where.not(team_id: nil).group(:team_id).count)
  end

  def label_unread_counts
    scope = scoped_thread_relation(include_labels: false, include_assignee: true)
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

  def scoped_thread_relation(include_status: true, include_inbox: true, include_assignee: false, include_team: true, include_labels: true)
    scope = base_thread_scope
    scope = apply_status_filter(scope) if include_status
    scope = apply_inbox_filter(scope) if include_inbox
    scope = apply_team_filter(scope) if include_team
    scope = apply_labels_filter(scope) if include_labels
    scope = apply_assignee_filter(scope) if include_assignee
    scope
  end

  def base_thread_scope
    CommunicationThread
      .where(account_id: current_account.id)
      .joins(:communication_thread_conversations)
      .where(communication_thread_conversations: { conversation_id: accessible_conversations.select(:id) })
      .distinct
  end

  def apply_status_filter(scope, status = nil)
    selected_status = status || params[:status]
    return scope if selected_status == 'all'

    status_value = selected_status.presence || DEFAULT_STATUS
    scope.where(
      'communication_threads.status = :thread_status OR communication_thread_conversations.conversation_id IN (:matching_conversation_ids)',
      thread_status: CommunicationThread.statuses.fetch(status_value),
      matching_conversation_ids: accessible_conversations
        .where(status: Conversation.statuses.fetch(status_value))
        .select(:id)
    )
  end

  def apply_inbox_filter(scope)
    return scope if params[:inbox_id].blank?

    scope.where(communication_thread_conversations: { inbox_id: params[:inbox_id] })
  end

  def apply_team_filter(scope)
    return scope if params[:team_id].blank?

    scope.where(team_id: params[:team_id])
  end

  def apply_labels_filter(scope)
    return scope if params[:labels].blank?

    labeled_conversation_ids = accessible_conversations.tagged_with(params[:labels], any: true).reselect(:id)
    scope.where(communication_thread_conversations: { conversation_id: labeled_conversation_ids })
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
    @communication_threads
      .includes(:contact, :assignee, :team)
      .order(Arel.sql(sort_clause))
      .page(params[:page] || 1)
      .per(RESULTS_PER_PAGE)
  end

  def sort_clause
    SORT_OPTIONS[params[:sort_by].presence || 'last_activity_at_desc']
  end

  def accessible_conversations
    @accessible_conversations ||= Conversations::PermissionFilterService.new(
      current_account.conversations,
      current_user,
      current_account
    ).perform
  end
end
