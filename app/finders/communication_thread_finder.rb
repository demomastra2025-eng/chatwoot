class CommunicationThreadFinder # rubocop:disable Metrics/ClassLength
  class InvalidParameter < StandardError; end

  attr_reader :current_user, :current_account, :params

  DEFAULT_STATUS = 'open'.freeze
  RESULTS_PER_PAGE = ENV.fetch('CONVERSATION_RESULTS_PER_PAGE', '25').to_i
  MAX_PAGE = 10_000
  MESSAGE_SEARCH_LOOKBACK = 3.months
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
    ].join(', '),
    'priority_desc_created_at_asc' => [
      'communication_threads.priority DESC NULLS LAST',
      'communication_threads.created_at ASC',
      'communication_threads.id ASC'
    ].join(', '),
    'waiting_since_asc' => [
      'thread_waiting_since_sort_at ASC NULLS LAST',
      'communication_threads.created_at ASC',
      'communication_threads.id ASC'
    ].join(', '),
    'waiting_since_desc' => [
      'thread_waiting_since_sort_at DESC NULLS LAST',
      'communication_threads.created_at ASC',
      'communication_threads.id ASC'
    ].join(', ')
  }.with_indifferent_access
  MESSAGE_SORT_KEYS = %w[last_activity_at_asc last_activity_at_desc latest].freeze
  WAITING_SORT_KEYS = %w[waiting_since_asc waiting_since_desc].freeze
  STATUS_COUNT_KEYS = %w[open pending snoozed resolved].freeze

  def self.message_sort?(sort_key)
    MESSAGE_SORT_KEYS.include?(sort_key.to_s)
  end

  def self.with_last_message_activity_sort(relation, conversation_scope)
    relation.joins(<<~SQL.squish).select(Arel.sql(<<~SELECT.squish))
      LEFT JOIN (#{last_message_activity_subquery_sql(conversation_scope)}) sort_thread_messages
        ON sort_thread_messages.communication_thread_id = communication_threads.id
       AND sort_thread_messages.account_id = communication_threads.account_id
    SQL
      communication_threads.*,
      COALESCE(sort_thread_messages.last_message_at, communication_threads.created_at) AS last_message_activity_sort_at
    SELECT
  end

  def self.last_message_activity_subquery_sql(conversation_scope)
    activity_message_type = Message.message_types[:activity]
    conversation_ids_sql = conversation_scope.reselect('conversations.id', 'conversations.account_id').to_sql

    <<~SQL.squish
      SELECT sort_thread_links.account_id, sort_thread_links.communication_thread_id, MAX(messages.created_at) AS last_message_at
      FROM communication_thread_conversations sort_thread_links
      INNER JOIN (#{conversation_ids_sql}) sort_accessible_conversations
        ON sort_accessible_conversations.id = sort_thread_links.conversation_id
       AND sort_accessible_conversations.account_id = sort_thread_links.account_id
      INNER JOIN messages ON messages.conversation_id = sort_thread_links.conversation_id
        AND messages.account_id = sort_thread_links.account_id
      WHERE messages.private = FALSE AND messages.message_type != #{activity_message_type}
      GROUP BY sort_thread_links.account_id, sort_thread_links.communication_thread_id
    SQL
  end

  def self.waiting_since_sort_sql(conversation_scope)
    conversation_ids_sql = conversation_scope.reselect('conversations.id').to_sql

    <<~SQL.squish
      SELECT MIN(sort_waiting_conversations.waiting_since)
      FROM communication_thread_conversations sort_waiting_links
      INNER JOIN conversations sort_waiting_conversations
        ON sort_waiting_conversations.id = sort_waiting_links.conversation_id
       AND sort_waiting_conversations.account_id = communication_threads.account_id
      INNER JOIN (#{conversation_ids_sql}) sort_accessible_conversations
        ON sort_accessible_conversations.id = sort_waiting_links.conversation_id
      WHERE sort_waiting_links.communication_thread_id = communication_threads.id
        AND sort_waiting_links.account_id = communication_threads.account_id
    SQL
  end

  def self.apply_search(relation, query)
    search_query = query.to_s.strip
    return relation if search_query.blank?

    escaped_query = ActiveRecord::Base.sanitize_sql_like(search_query)
    search = "%#{escaped_query}%"
    phone_search = "%#{ActiveRecord::Base.sanitize_sql_like(search_query.gsub(/\s+/, ''))}%"
    message_types = [Message.message_types[:incoming], Message.message_types[:outgoing]].join(', ')

    relation.left_joins(:contact).where(
      <<~SQL.squish,
        CAST(communication_threads.display_id AS TEXT) ILIKE :search
        OR contacts.name ILIKE :search
        OR contacts.email ILIKE :search
        OR contacts.identifier ILIKE :search
        OR contacts.additional_attributes ->> 'company_name' ILIKE :search
        OR regexp_replace(COALESCE(contacts.phone_number, ''), '\s+', '', 'g') ILIKE :phone_search
        OR EXISTS (
          SELECT 1
          FROM communication_thread_conversations search_thread_links
          INNER JOIN messages search_messages
            ON search_messages.conversation_id = search_thread_links.conversation_id
           AND search_messages.account_id = search_thread_links.account_id
          WHERE search_thread_links.communication_thread_id = communication_threads.id
            AND search_thread_links.account_id = communication_threads.account_id
            AND search_messages.created_at >= :message_search_since
            AND search_messages.message_type IN (#{message_types})
            AND search_messages.content ILIKE :search
        )
      SQL
      search: search,
      phone_search: phone_search,
      message_search_since: MESSAGE_SEARCH_LOOKBACK.ago
    )
  end

  def initialize(current_user, params = nil, operational: false, **legacy_params)
    @current_user = current_user
    @current_account = current_user.account
    @params = params || legacy_params
    @operational = operational
  end

  def perform
    set_up
    count = include_meta? ? thread_counts : {}
    filter_by_assignee_type
    threads = communication_threads

    {
      communication_threads: threads,
      count: count,
      pagination: pagination_metadata
    }
  end

  def perform_meta_only
    set_up

    { count: thread_counts }
  end

  def perform_sidebar_unread_counts
    validate_params!
    unread_counts
  end

  def perform_scope
    set_up
    filter_by_assignee_type
    @communication_threads
  end

  private

  def set_up
    validate_params!
    find_accessible_threads
    filter_by_query
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
    @communication_threads = base_thread_scope
    @communication_threads = @communication_threads.where(id: participating_thread_ids) if params[:conversation_type] == 'participating'
    @communication_threads = @communication_threads.left_joins(:communication_thread_conversations).distinct
  end

  def filter_by_query
    @communication_threads = self.class.apply_search(@communication_threads, params[:q])
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
    counts = aggregate_assignment_counts(@communication_threads, include_unread: true)

    [
      counts[:mine_count],
      counts[:unassigned_count],
      counts[:all_count],
      counts[:mine_unread_count],
      counts[:unassigned_unread_count],
      counts[:all_unread_count]
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
      participating_count: participating_count,
      assignee_counts: assignee_counts(mine_count, unassigned_count, all_count),
      unread_counts: include_context_counts? ? unread_counts : {},
      context_counts: include_context_counts? ? context_counts : {}
    }
  end

  def assignee_counts(mine_count, unassigned_count, all_count)
    {
      mine_count: mine_count,
      assigned_count: all_count - unassigned_count,
      unassigned_count: unassigned_count,
      all_count: all_count
    }
  end

  def participating_count
    CommunicationThreadParticipant.where(account_id: current_account.id, user_id: current_user.id).count
  end

  def context_counts
    scope = scoped_thread_relation(
      include_crm_deal_context: false,
      include_scheduling_appointment_context: false,
      include_assignee: false,
      include_unread: false
    )
    crm_service = Crm::DealDialogUnreadCountService.new(
      account: current_account,
      communication_thread_scope: scope
    )
    appointment_service = Scheduling::AppointmentDialogCountService.new(
      account: current_account,
      communication_thread_scope: scope
    )

    {
      pipelines: crm_service.communication_thread_pipeline_counts,
      stages: crm_service.communication_thread_stage_counts,
      appointment_statuses: appointment_service.communication_thread_status_counts
    }
  end

  def assignee_counts_for(scope)
    counts = aggregate_assignment_counts(scope)
    mine_count = counts[:mine_count]
    unassigned_count = counts[:unassigned_count]
    all_count = counts[:all_count]

    {
      mine_count: mine_count,
      assigned_count: all_count - unassigned_count,
      unassigned_count: unassigned_count,
      all_count: all_count
    }
  end

  def aggregate_assignment_counts(scope, include_unread: false)
    relation = CommunicationThread.where(id: scope.except(:order).select(:id))
    columns = assignment_count_columns
    columns += unread_assignment_count_columns if include_unread

    assignment_counts_from(relation.pick(*columns))
  end

  def assignment_count_columns
    [
      Arel.sql('COUNT(*)'),
      Arel.sql("COUNT(*) FILTER (WHERE communication_threads.assignee_id = #{current_user.id.to_i})"),
      Arel.sql('COUNT(*) FILTER (WHERE communication_threads.assignee_id IS NULL)')
    ]
  end

  def unread_assignment_count_columns
    [
      Arel.sql('COUNT(*) FILTER (WHERE communication_threads.unread_count > 0)'),
      Arel.sql(
        'COUNT(*) FILTER (WHERE communication_threads.unread_count > 0 AND ' \
        "communication_threads.assignee_id = #{current_user.id.to_i})"
      ),
      Arel.sql(
        'COUNT(*) FILTER (WHERE communication_threads.unread_count > 0 AND ' \
        'communication_threads.assignee_id IS NULL)'
      )
    ]
  end

  def assignment_counts_from(raw_values)
    values = Array(raw_values).map(&:to_i)
    {
      all_count: values[0],
      mine_count: values[1],
      unassigned_count: values[2],
      all_unread_count: values[3].to_i,
      mine_unread_count: values[4].to_i,
      unassigned_unread_count: values[5].to_i
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

    CommunicationThreads::UnreadStatusCountService.new(
      account: current_account,
      thread_scope: unread_thread_scope(scope),
      conversation_scope: accessible_conversations
    ).perform
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
    unread_conversations = Conversations::UnreadScopeBuilder.new(
      scope: accessible_conversations,
      account: current_account,
      user: current_user
    ).perform.select(:id)
    base_scope = CommunicationThread.where(id: scope.except(:order).select(:id))
    base_scope.where(id: thread_ids_for_conversations(unread_conversations)).or(legacy_unread_thread_scope(base_scope))
  end

  def legacy_unread_thread_scope(scope)
    user_states = ConversationUserReadState.where(
      account_id: current_account.id,
      user_id: current_user.id
    ).select(:conversation_id)
    legacy_scope = scope.where('communication_threads.unread_count > 0')
                        .where.not(id: thread_ids_for_conversations(user_states))
    return legacy_scope if policy_user_context[:account_user]&.administrator?

    legacy_inbox_thread_ids = CommunicationThreadConversation
                              .where(
                                account_id: current_account.id,
                                inbox_id: current_user.inboxes.where(account_id: current_account.id).select(:id)
                              )
                              .select(:communication_thread_id)
    legacy_scope.where(id: legacy_inbox_thread_ids).or(legacy_scope.where(id: participating_thread_ids))
  end

  def thread_ids_for_conversations(conversations)
    CommunicationThreadConversation
      .where(account_id: current_account.id, conversation_id: conversations)
      .select(:communication_thread_id)
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
    return visible_thread_scope if access_role_enforced?

    account_threads = CommunicationThread.where(account_id: current_account.id)
    account_threads.where(id: linked_thread_ids).or(account_threads.where(id: participating_thread_ids))
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
    relation = with_waiting_since_sort(relation) if waiting_sort?

    relation
      .includes(thread_list_preloads)
      .order(Arel.sql(sort_clause))
      .page(current_page)
      .per(RESULTS_PER_PAGE)
  end

  def current_page
    (Integer(params[:page], exception: false) || 1).clamp(1, MAX_PAGE)
  end

  def pagination_metadata
    total_count = CommunicationThread.where(
      id: @communication_threads.except(:order).select(:id)
    ).count

    {
      count: total_count,
      current_page: current_page,
      per_page: RESULTS_PER_PAGE,
      total_pages: (total_count.to_f / RESULTS_PER_PAGE).ceil,
      has_more: current_page * RESULTS_PER_PAGE < total_count
    }
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

  def waiting_sort?
    WAITING_SORT_KEYS.include?(sort_key.to_s)
  end

  def with_last_message_activity_sort(relation)
    self.class.with_last_message_activity_sort(relation, accessible_conversations)
  end

  def with_waiting_since_sort(relation)
    sort_sql = self.class.waiting_since_sort_sql(accessible_conversations)

    relation.select(
      Arel.sql("communication_threads.*, (#{sort_sql}) AS thread_waiting_since_sort_at")
    )
  end

  def include_meta?
    !params.key?(:include_meta) || ActiveModel::Type::Boolean.new.cast(params[:include_meta])
  end

  def include_context_counts?
    ActiveModel::Type::Boolean.new.cast(params[:include_context_counts])
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
      :communication_thread_participants,
      :team
    ]
  end

  def accessible_conversations
    @accessible_conversations ||= begin
      permission_service = Conversations::PermissionFilterService.new(
        current_account.conversations,
        current_user,
        current_account
      )
      scope = @operational ? permission_service.perform_operational : permission_service.perform
      scope = merge_additional_conversation_access(scope)
      filter_conversations_by_type(scope)
    end
  end

  def merge_additional_conversation_access(scope)
    base_scope = current_account.conversations
    base_scope.where(id: scope.select(:id)).or(base_scope.where(id: additional_conversation_scope.select(:id)))
  end

  def additional_conversation_scope
    thread_ids = access_role_enforced? ? visible_thread_scope.select(:id) : participating_thread_ids
    current_account.conversations.where(
      id: CommunicationThreadConversation.where(
        account_id: current_account.id,
        communication_thread_id: thread_ids
      ).select(:conversation_id)
    )
  end

  def filter_conversations_by_type(scope)
    case params[:conversation_type]
    when 'mention'
      scope.where(id: current_account.mentions.where(user: current_user).select(:conversation_id))
    when 'participating'
      scope.where(id: participating_conversation_ids)
    when 'unattended'
      scope.unattended
    else
      scope
    end
  end

  def participating_conversation_ids
    CommunicationThreadConversation.where(
      account_id: current_account.id,
      communication_thread_id: participating_thread_ids
    ).select(:conversation_id)
  end

  def participating_thread_ids
    @participating_thread_ids ||= CommunicationThreadParticipant
                                  .where(account_id: current_account.id, user_id: current_user.id)
                                  .select(:communication_thread_id)
  end

  def visible_thread_scope
    @visible_thread_scope ||= CommunicationThreadPolicy::Scope.new(
      policy_user_context,
      CommunicationThread.where(account_id: current_account.id)
    ).resolve
  end

  def access_role_enforced?
    @access_role_enforced ||= AccessControl::ModeResolver.call(
      account_user: policy_user_context[:account_user],
      resource: 'conversations',
      capability: 'view'
    ).authoritative_source == 'access_role'
  end

  def policy_user_context
    @policy_user_context ||= {
      user: current_user,
      account: current_account,
      account_user: current_account.account_users.find_by(user_id: current_user.id)
    }
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
