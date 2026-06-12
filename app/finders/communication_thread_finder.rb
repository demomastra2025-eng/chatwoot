class CommunicationThreadFinder
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

  def initialize(current_user, params)
    @current_user = current_user
    @current_account = current_user.account
    @params = params
  end

  def perform
    set_up
    mine_count, unassigned_count, all_count = set_count_for_all_threads
    assigned_count = all_count - unassigned_count
    filter_by_assignee_type

    {
      communication_threads: communication_threads,
      count: {
        mine_count: mine_count,
        assigned_count: assigned_count,
        unassigned_count: unassigned_count,
        all_count: all_count
      }
    }
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
    [
      @communication_threads.where(assignee_id: current_user.id).count,
      @communication_threads.where(assignee_id: nil).count,
      @communication_threads.count
    ]
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
