class ConversationFinder # rubocop:disable Metrics/ClassLength
  attr_reader :current_user, :current_account, :params

  DEFAULT_STATUS = 'open'.freeze
  COUNT_RELATION_FILTERS = {
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
    'last_activity_at_asc' => %w[sort_on_last_message_at asc],
    'last_activity_at_desc' => %w[sort_on_last_message_at desc],
    'last_event_activity_at_asc' => %w[sort_on_last_activity_at asc],
    'last_event_activity_at_desc' => %w[sort_on_last_activity_at desc],
    'created_at_asc' => %w[sort_on_created_at asc],
    'created_at_desc' => %w[sort_on_created_at desc],
    'priority_asc' => %w[sort_on_priority asc],
    'priority_desc' => %w[sort_on_priority desc],
    'waiting_since_asc' => %w[sort_on_waiting_since asc],
    'waiting_since_desc' => %w[sort_on_waiting_since desc],
    'priority_desc_created_at_asc' => %w[sort_on_priority_created_at desc],

    # To be removed in v3.5.0
    'latest' => %w[sort_on_last_message_at desc],
    'sort_on_created_at' => %w[sort_on_created_at asc],
    'sort_on_priority' => %w[sort_on_priority desc],
    'sort_on_waiting_since' => %w[sort_on_waiting_since asc]
  }.with_indifferent_access
  # assumptions
  # inbox_id if not given, take from all conversations, else specific to inbox
  # assignee_type if not given, take 'all'
  # conversation_status if not given, take 'open'

  # response of this class will be of type
  # {conversations: [array of conversations], count: {open: count, resolved: count}}

  # params
  # assignee_type, inbox_id, :status

  def initialize(current_user, params)
    @current_user = current_user
    @current_account = current_user.account
    @is_admin = current_account.account_users.find_by(user_id: current_user.id)&.administrator?
    @params = params
  end

  def perform
    set_up

    count = conversation_counts

    filter_by_assignee_type

    {
      conversations: conversations,
      count: count
    }
  end

  def perform_meta_only
    set_up

    { count: conversation_counts }
  end

  private

  def set_up
    set_inboxes
    set_team
    set_assignee_type

    find_all_conversations
    filter_by_status unless params[:q]
    filter_by_team
    filter_by_labels
    filter_by_crm_deal_context
    filter_by_scheduling_appointment_context
    filter_by_unread
    filter_by_query
    filter_by_source_id
  end

  def set_inboxes
    @inbox_ids = if params[:inbox_id]
                   @current_user.assigned_inboxes.where(id: params[:inbox_id])
                 else
                   @current_user.assigned_inboxes.pluck(:id)
                 end
  end

  def set_assignee_type
    @assignee_type = params[:assignee_type]
  end

  def set_team
    @team = current_account.teams.find(params[:team_id]) if params[:team_id]
  end

  def find_conversation_by_inbox
    @conversations = current_account.conversations

    return unless params[:inbox_id]

    @conversations = @conversations.where(inbox_id: @inbox_ids)
  end

  def find_all_conversations
    find_conversation_by_inbox
    # Apply permission-based filtering
    @conversations = Conversations::PermissionFilterService.new(
      @conversations,
      current_user,
      current_account
    ).perform
    filter_by_conversation_type if params[:conversation_type]
    @conversations
  end

  def filter_by_assignee_type
    case @assignee_type
    when 'me'
      @conversations = @conversations.assigned_to(current_user)
    when 'unassigned'
      @conversations = @conversations.unassigned
    when 'assigned'
      @conversations = @conversations.assigned
    end
    @conversations
  end

  def filter_by_conversation_type
    case @params[:conversation_type]
    when 'mention'
      conversation_ids = current_account.mentions.where(user: current_user).pluck(:conversation_id)
      @conversations = @conversations.where(id: conversation_ids)
    when 'participating'
      @conversations = current_user.participating_conversations.where(account_id: current_account.id)
    when 'unattended'
      @conversations = @conversations.unattended
    end
    @conversations
  end

  def filter_by_query
    return unless params[:q]

    allowed_message_types = [Message.message_types[:incoming], Message.message_types[:outgoing]]
    @conversations = conversations.joins(:messages).where('messages.content ILIKE :search', search: "%#{params[:q]}%")
                                  .where(messages: { message_type: allowed_message_types }).includes(:messages)
                                  .where('messages.content ILIKE :search', search: "%#{params[:q]}%")
                                  .where(messages: { message_type: allowed_message_types })
  end

  def filter_by_status
    return if params[:status] == 'all'

    @conversations = @conversations.where(status: params[:status] || DEFAULT_STATUS)
  end

  def filter_by_team
    if @team
      @conversations = @conversations.where(team: @team)
      return
    end

    @conversations = @conversations.where.not(team_id: nil) if team_scope_any?
  end

  def filter_by_labels
    if params[:labels].present?
      @conversations = @conversations.tagged_with(params[:labels], any: true)
      return
    end

    @conversations = conversations_with_any_label(@conversations) if labels_scope_any?
  end

  def filter_by_crm_deal_context
    @conversations = current_crm_deal_dialog_scope.filter_conversations(@conversations)
  end

  def filter_by_scheduling_appointment_context
    @conversations = current_scheduling_appointment_dialog_scope.filter_conversations(@conversations)
  end

  def filter_by_unread
    @conversations = apply_unread_filter(@conversations)
  end

  def filter_by_source_id
    return unless params[:source_id]

    @conversations = @conversations.joins(:contact_inbox)
    @conversations = @conversations.where(contact_inboxes: { source_id: params[:source_id] })
  end

  def set_count_for_all_conversations
    assignee_counts_for(@conversations).values_at(:mine_count, :unassigned_count, :all_count)
  end

  def conversation_counts
    filtered_counts = assignee_counts_for(@conversations)

    filtered_counts.merge(
      assignee_counts: assignee_counts_for(base_count_scope),
      unread_counts: unread_counts
    )
  end

  def assignee_counts_for(scope)
    mine_count = scope.assigned_to(current_user).count
    unassigned_count = scope.unassigned.count
    all_count = scope.count

    {
      mine_count: mine_count,
      assigned_count: all_count - unassigned_count,
      unassigned_count: unassigned_count,
      all_count: all_count
    }
  end

  def unread_counts
    {
      all: unread_dialog_count(scoped_count_relation(include_inbox: false, include_assignee: true, include_unread: false)),
      statuses: status_unread_counts,
      inboxes: inbox_unread_counts,
      teams: team_unread_counts,
      labels: label_unread_counts,
      pipelines: pipeline_unread_counts,
      stages: stage_unread_counts,
      appointment_statuses: appointment_status_unread_counts
    }
  end

  def status_unread_counts
    scope = scoped_count_relation(include_status: false, include_assignee: true, include_unread: false)
    unread_scope = unread_conversation_scope(scope)

    normalize_enum_counts(unread_scope.group(:status).distinct.count('conversations.id'), Conversation.statuses)
  end

  def inbox_unread_counts
    scope = scoped_count_relation(include_inbox: false, include_assignee: true, include_unread: false)
    unread_scope = unread_conversation_scope(scope)

    normalize_counts(unread_scope.group(:inbox_id).distinct.count('conversations.id'))
  end

  def team_unread_counts
    scope = scoped_count_relation(include_team: false, include_assignee: true, include_unread: false)
    unread_scope = unread_conversation_scope(scope)

    normalize_counts(unread_scope.where.not(team_id: nil).group(:team_id).distinct.count('conversations.id'))
  end

  def label_unread_counts
    scope = scoped_count_relation(include_labels: false, include_assignee: true, include_unread: false)
    unread_scope = unread_conversation_scope(scope)

    normalize_counts(label_counts(unread_scope))
  end

  def pipeline_unread_counts
    crm_unread_count_service.conversation_pipeline_counts
  end

  def stage_unread_counts
    crm_unread_count_service.conversation_stage_counts
  end

  def appointment_status_unread_counts
    scheduling_appointment_count_service.conversation_status_counts
  end

  def unread_conversation_scope(scope)
    scope.joins(:messages)
         .where(messages: unread_message_filters)
         .where(
           'messages.created_at > COALESCE(conversations.agent_last_seen_at, ?)',
           Time.zone.at(0)
         )
  end

  def unread_dialog_count(scope)
    unread_conversation_scope(scope).distinct.count('conversations.id')
  end

  def unread_message_filters
    {
      account_id: current_account.id,
      message_type: Message.message_types[:incoming],
      private: false
    }
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

  def scoped_count_relation(filters = {})
    filters = COUNT_RELATION_FILTERS.merge(filters)

    [
      [:include_inbox, method(:apply_inbox_filter)],
      [:include_status, method(:apply_status_count_filter)],
      [:include_team, method(:apply_team_filter)],
      [:include_labels, method(:apply_labels_filter)],
      [:include_crm_deal_context, method(:apply_crm_deal_context_filter)],
      [:include_scheduling_appointment_context, method(:apply_scheduling_appointment_context_filter)],
      [:include_source_id, method(:apply_source_id_filter)],
      [:include_unread, method(:apply_unread_filter)],
      [:include_assignee, method(:apply_assignee_filter)]
    ].reduce(base_count_scope) do |scope, (filter_key, filter_method)|
      filters.fetch(filter_key, true) ? filter_method.call(scope) : scope
    end
  end

  def base_count_scope
    scope = Conversations::PermissionFilterService.new(
      current_account.conversations,
      current_user,
      current_account
    ).perform
    apply_conversation_type_filter(scope)
  end

  def apply_conversation_type_filter(scope)
    case @params[:conversation_type]
    when 'mention'
      conversation_ids = current_account.mentions.where(user: current_user).pluck(:conversation_id)
      scope.where(id: conversation_ids)
    when 'participating'
      current_user.participating_conversations.where(account_id: current_account.id)
    when 'unattended'
      scope.unattended
    else
      scope
    end
  end

  def apply_inbox_filter(scope)
    return scope unless params[:inbox_id]

    scope.where(inbox_id: @inbox_ids)
  end

  def apply_status_filter(scope, status = nil)
    selected_status = status || params[:status]
    return scope if selected_status == 'all'

    scope.where(status: selected_status.presence || DEFAULT_STATUS)
  end

  def apply_status_count_filter(scope)
    return scope if params[:q]

    apply_status_filter(scope)
  end

  def apply_team_filter(scope)
    return scope.where(team: @team) if @team
    return scope.where.not(team_id: nil) if team_scope_any?

    scope
  end

  def apply_labels_filter(scope)
    return scope.tagged_with(params[:labels], any: true) if params[:labels].present?
    return conversations_with_any_label(scope) if labels_scope_any?

    scope
  end

  def apply_crm_deal_context_filter(scope)
    current_crm_deal_dialog_scope.filter_conversations(scope)
  end

  def apply_scheduling_appointment_context_filter(scope)
    current_scheduling_appointment_dialog_scope.filter_conversations(scope)
  end

  def apply_unread_filter(scope)
    return scope unless unread_only?

    scope.where(id: unread_conversation_scope(scope).reselect('conversations.id'))
  end

  def apply_source_id_filter(scope)
    return scope unless params[:source_id]

    scope.joins(:contact_inbox).where(contact_inboxes: { source_id: params[:source_id] })
  end

  def apply_assignee_filter(scope)
    case @assignee_type
    when 'me'
      scope.assigned_to(current_user)
    when 'unassigned'
      scope.unassigned
    when 'assigned'
      scope.assigned
    else
      scope
    end
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
      conversation_scope: crm_unread_conversation_scope
    )
  end

  def crm_unread_conversation_scope
    @crm_unread_conversation_scope ||= unread_conversation_scope(
      scoped_count_relation(include_crm_deal_context: false, include_assignee: true, include_unread: false)
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
      conversation_scope: scheduling_appointment_count_conversation_scope
    )
  end

  def scheduling_appointment_count_conversation_scope
    @scheduling_appointment_count_conversation_scope ||= unread_conversation_scope(
      scoped_count_relation(
        include_scheduling_appointment_context: false,
        include_assignee: true,
        include_unread: false
      )
    )
  end

  def search_query_last_message_sort?(sort_by)
    params[:q].present? && sort_by == 'sort_on_last_message_at'
  end

  def current_page
    params[:page] || 1
  end

  def conversations_base_query
    @conversations.includes(
      :taggings, :inbox, { assignee: { avatar_attachment: [:blob] } }, { contact: { avatar_attachment: [:blob] } },
      :team, :conversation_participants, { contact_inbox: :channel_profile }, :assignee_agent_bot
    )
  end

  def conversations
    @conversations = conversations_base_query

    sort_by, sort_order = SORT_OPTIONS[params[:sort_by]] || SORT_OPTIONS['last_activity_at_desc']
    sort_by, sort_order = SORT_OPTIONS['last_event_activity_at_desc'] if search_query_last_message_sort?(sort_by)
    @conversations = @conversations.send(sort_by, sort_order)

    if params[:updated_within].present?
      @conversations.where('conversations.updated_at > ?', Time.zone.now - params[:updated_within].to_i.seconds)
    else
      @conversations.page(current_page).per(ENV.fetch('CONVERSATION_RESULTS_PER_PAGE', '25').to_i)
    end
  end
end
ConversationFinder.prepend_mod_with('ConversationFinder')
