class Api::V1::Accounts::CommunicationThreadsController < Api::V1::Accounts::BaseController
  include CommunicationThreads::ControllerContext

  FEATURE_NAME = 'communication_threads'.freeze
  ATTACHMENT_RESULTS_PER_PAGE = 100
  MEMBER_THREAD_ACTIONS = [
    :show,
    :update,
    :messages,
    :channels,
    :attachments,
    :labels,
    :update_labels,
    :destroy_conversations,
    :create_message,
    :update_last_seen,
    :unread
  ].freeze

  rescue_from CommunicationThreadFinder::InvalidParameter, with: :render_communication_thread_parameter_error
  rescue_from CommunicationThreads::MessageCreateService::Error, with: :render_message_create_error
  rescue_from Conversations::StatusReasonConfig::Error, with: :render_status_reason_error
  rescue_from ArgumentError, with: :render_communication_thread_parameter_error
  rescue_from Conversations::DeletionService::InvalidRequest, with: :render_invalid_deletion
  rescue_from Conversations::DeletionService::KeyConflict, with: :render_deletion_key_conflict
  rescue_from Conversations::DeletionService::OverlappingRequest, with: :render_deletion_key_conflict

  before_action :ensure_communication_threads_feature_enabled!
  before_action :recover_deletion, only: :destroy_conversations
  before_action :communication_thread, only: MEMBER_THREAD_ACTIONS
  before_action :ensure_thread_accessible!, only: MEMBER_THREAD_ACTIONS
  before_action :ensure_full_thread_accessible_for_update!, only: [:update]
  before_action :validate_update_params!, only: [:update]
  around_action :with_list_presence_cache, only: [:index, :filter, :list_search]

  def index
    result = CommunicationThreadFinder.new(Current.user, params).perform
    @communication_threads = result[:communication_threads]
    @communication_threads_count = result[:count]
    preload_accessible_links(@communication_threads)
    preload_crm_deal_stages(@communication_threads)
    preload_meta_ad_referrals(@communication_threads)
  end

  # Search box of the conversation list. Takes only `q` and `page`: the list filters (status, assignee, inbox, team,
  # labels, CRM stage, unread) are never applied here, see CommunicationThreads::ListSearchService.
  def list_search
    result = CommunicationThreads::ListSearchService.new(user: Current.user, account: Current.account, params: params).perform
    @communication_threads = result[:communication_threads]
    @communication_threads_count = result[:count]
    preload_accessible_links(@communication_threads)
    preload_crm_deal_stages(@communication_threads)
    preload_meta_ad_referrals(@communication_threads)
  end

  def meta
    result = CommunicationThreadFinder.new(Current.user, params).perform_meta_only

    render json: { meta: result[:count] }
  end

  def sidebar_unread_counts
    @sidebar_unread_counts = CommunicationThreadFinder.new(Current.user, params).perform_sidebar_unread_counts
  end

  def filter
    result = CommunicationThreads::FilterService.new(params.permit!, Current.user, Current.account).perform
    @communication_threads = result[:communication_threads]
    @communication_threads_count = result[:count]
    preload_accessible_links(@communication_threads)
    preload_crm_deal_stages(@communication_threads)
    preload_meta_ad_referrals(@communication_threads)
    render :index
  rescue CustomExceptions::CustomFilter::InvalidAttribute,
         CustomExceptions::CustomFilter::InvalidOperator,
         CustomExceptions::CustomFilter::InvalidQueryOperator,
         CustomExceptions::CustomFilter::InvalidValue => e
    render_could_not_create_error(e.message)
  end

  def filter_sidebar_unread_counts
    @sidebar_unread_counts = CommunicationThreads::FilterService
                             .new(params.permit!, Current.user, Current.account)
                             .perform_sidebar_unread_counts
    render :sidebar_unread_counts
  rescue CustomExceptions::CustomFilter::InvalidAttribute,
         CustomExceptions::CustomFilter::InvalidOperator,
         CustomExceptions::CustomFilter::InvalidQueryOperator,
         CustomExceptions::CustomFilter::InvalidValue => e
    render_could_not_create_error(e.message)
  end

  def show
    preload_accessible_links([@communication_thread], include_unlinked: true)
    preload_crm_deal_stages([@communication_thread])
    preload_meta_ad_referrals([@communication_thread])
  end

  def update
    @communication_thread = CommunicationThreads::UpdateService.new(
      communication_thread: @communication_thread,
      params: permitted_update_params,
      accessible_links: accessible_links_for(@communication_thread),
      actor: Current.user,
      source: 'communication_thread'
    ).perform
    preload_accessible_links([@communication_thread], include_unlinked: true)
    preload_crm_deal_stages([@communication_thread])
    preload_meta_ad_referrals([@communication_thread])
    render :show
  end

  def channels
    preload_accessible_links([@communication_thread], include_unlinked: true, include_list_context: false)
  end

  def messages
    preload_accessible_links([@communication_thread], include_unlinked: true, include_list_context: false)
    @messages = CommunicationThreadMessageFinder.new(
      communication_thread: @communication_thread,
      current_user: Current.user,
      params: params
    ).perform
    @first_unread_message_id = first_unread_message_id_for(@communication_thread) if first_unread_cursor_requested?
  end

  def attachments
    conversation_ids = accessible_links_for(@communication_thread).select(:conversation_id)
    message_ids = Message.where(account_id: Current.account.id, conversation_id: conversation_ids).select(:id)
    @attachments_count = Attachment.where(message_id: message_ids).count
    @attachments = Attachment.where(message_id: message_ids)
                             .includes(
                               { file_attachment: :blob },
                               message: [
                                 :inbox,
                                 :sender,
                                 { conversation: { contact_inbox: :channel_profile } }
                               ]
                             )
                             .order(created_at: :desc, id: :desc)
                             .page(attachment_params[:page])
                             .per(ATTACHMENT_RESULTS_PER_PAGE)
  end

  def labels
    @labels = thread_label_list
  end

  # Labels are the person's: the change goes to the contact and to every conversation of the thread, also to the channels
  # this agent cannot open, and one change is reported once (Labels::UnifiedAssignmentService), by the conversation in
  # front of the person, the one whose status the dialog shows. The answer is what this agent can see.
  def update_labels
    add, remove = Labels::UnifiedAssignmentService.delta_from_params(
      permitted_label_params,
      visible_labels: Labels::UnifiedAssignmentService.union_for(contact: nil, conversations: accessible_thread_conversations)
    )
    Labels::UnifiedAssignmentService.new(contact: @communication_thread.contact, add: add, remove: remove).perform
    @labels = thread_label_list
    render :labels
  end

  def destroy_conversations
    conversations = selected_delete_conversations
    authorize_delete_conversations!(conversations)
    run = deletion_service.create(
      conversations: conversations, request_key: params.key?(:request_key) ? params[:request_key] : SecureRandom.uuid,
      conversation_ids: permitted_delete_conversation_ids, thread_id: params[:id], ip: request.ip
    )
    render_deletion(run)
  end

  def create_message
    service = CommunicationThreads::MessageCreateService.new(
      contact: @communication_thread.contact,
      current_user: Current.user,
      params: permitted_message_params,
      accessible_inboxes: accessible_inboxes,
      accessible_conversations: accessible_conversations
    )
    @message = service.perform
    @communication_thread = service.communication_thread
    preload_accessible_links([@communication_thread], include_unlinked: true)
    preload_crm_deal_stages([@communication_thread])
    preload_meta_ad_referrals([@communication_thread])
    render :message
  end

  def update_last_seen
    service = CommunicationThreads::MarkReadService.new(
      communication_thread: @communication_thread,
      current_user: Current.user,
      current_account: Current.account,
      accessible_links: accessible_links_for(@communication_thread)
    )
    @communication_thread = service.perform
    channel_read_states = service.channel_read_states
    render json: {
      id: @communication_thread.display_id,
      unread_count: channel_read_states.sum { |state| state[:unread_count] },
      agent_last_seen_at: service.last_seen_at&.to_i,
      read_state_changed: service.read_state_changed,
      sidebar_counts_refresh_required: service.sidebar_counts_refresh_required,
      channels: channel_read_states
    }
  end

  def unread
    @communication_thread = CommunicationThreads::MarkUnreadService.new(
      communication_thread: @communication_thread,
      accessible_links: accessible_links_for(@communication_thread),
      current_user: Current.user
    ).perform
    preload_accessible_links([@communication_thread], include_unlinked: true)
    preload_crm_deal_stages([@communication_thread])
    preload_meta_ad_referrals([@communication_thread])
    render :show
  end

  private

  def deletion_service
    @deletion_service ||= Conversations::DeletionService.new(account: Current.account, user: Current.user)
  end

  def recover_deletion
    Conversations::DeletionService.identity(params[:id])
    permitted_delete_conversation_ids
    return unless params.key?(:request_key)

    run = deletion_service.recover(
      request_key: params[:request_key], conversation_ids: permitted_delete_conversation_ids, thread_id: params[:id]
    )
    render_deletion(run) if run
  end

  def render_deletion(run)
    enqueue_failed = run.metadata.fetch('targets').any? { |target| target['error_code'] == 'enqueue_failed' }
    render json: Conversations::DeletionService.response(run).merge(thread_id: params[:id].to_i),
           status: enqueue_failed ? :service_unavailable : :accepted
  end

  def render_invalid_deletion
    render json: { error: 'conversation_deletion_invalid' }, status: :unprocessable_content
  end

  def render_deletion_key_conflict
    render json: { error: 'conversation_deletion_key_conflict' }, status: :conflict
  end

  def communication_thread
    @communication_thread = CommunicationThread.find_by!(account_id: Current.account.id, display_id: params[:id])
  end

  def first_unread_message_id_for(communication_thread)
    conversation_ids = accessible_links_for(communication_thread).select(:conversation_id)

    messages = Message.without_imported_history
                      .joins(:conversation)
                      .where(
                        account_id: Current.account.id,
                        conversation_id: conversation_ids,
                        message_type: Message.message_types[:incoming],
                        private: false
                      )
    messages = messages.where(
      "messages.created_at > COALESCE(conversations.agent_last_seen_at, '-infinity'::timestamp)"
    )
    messages = messages.where('messages.created_at >= ?', communication_thread.session_started_at) if communication_thread.session_started_at?

    messages.reorder('messages.created_at ASC', 'messages.id ASC').limit(1).pick(:id)
  end

  def first_unread_cursor_requested?
    params[:after].blank? && params[:before].blank?
  end

  def permitted_update_params
    params.permit(
      :status,
      :priority,
      :assignee_id,
      :assignee_type,
      :team_id,
      :snoozed_until,
      :status_reason,
      custom_attributes: {},
      destroy_custom_attributes: []
    )
  end

  def attachment_params
    params.permit(:page)
  end

  def permitted_label_params
    params.permit(:id, labels: [], add: [], remove: [])
  end

  def permitted_delete_conversation_ids
    raw_ids = params[:conversation_ids]
    raise Conversations::DeletionService::InvalidRequest unless raw_ids.is_a?(Array) && raw_ids.size.between?(1, Conversations::DeletionService::MAX_TARGETS)
    raise ArgumentError, 'Select at least one communication thread conversation' if raw_ids.blank?

    ids = raw_ids.map { |conversation_id| Conversations::DeletionService.identity(conversation_id) }
    raise Conversations::DeletionService::InvalidRequest unless ids.uniq.size == ids.size

    ids
  rescue ArgumentError, TypeError
    raise ArgumentError, 'Invalid communication thread conversation_ids'
  end

  def selected_delete_conversations
    conversation_ids = permitted_delete_conversation_ids
    selected_links = accessible_links_for(@communication_thread)
                     .includes(:conversation)
                     .select { |link| conversation_ids.include?(link.conversation.display_id) }

    raise ArgumentError, 'Invalid communication thread conversation_ids' if selected_links.size != conversation_ids.size

    selected_links.map(&:conversation)
  end

  def authorize_delete_conversations!(conversations)
    conversations.each { |conversation| authorize conversation, :destroy? }
  end

  def thread_label_list
    Labels::UnifiedAssignmentService.union_for(
      contact: @communication_thread.contact,
      conversations: accessible_thread_conversations
    )
  end

  def accessible_thread_conversations
    accessible_links_for(@communication_thread).includes(:conversation).map(&:conversation)
  end

  def validate_update_params!
    validate_enum_param!(:status, CommunicationThread.statuses.keys)
    validate_enum_param!(:priority, CommunicationThread.priorities.keys)
    validate_assignee_type!
    validate_assignee!
    validate_team!
  end

  def validate_enum_param!(key, allowed_values)
    return unless params.key?(key)
    return if params[key].blank? || allowed_values.include?(params[key].to_s)

    raise ArgumentError, "Invalid communication thread #{key}: #{params[key]}"
  end

  def validate_assignee_type!
    return if params[:assignee_type].blank?
    return if params[:assignee_type].to_s == 'User'

    raise ArgumentError, "Invalid communication thread assignee_type: #{params[:assignee_type]}"
  end

  def validate_assignee!
    return unless params.key?(:assignee_id) && params[:assignee_id].present?

    return if Current.account.account_users.exists?(user_id: params[:assignee_id])

    raise ArgumentError, "Invalid communication thread assignee_id: #{params[:assignee_id]}"
  end

  def validate_team!
    return unless params.key?(:team_id) && params[:team_id].present?
    return if Current.account.teams.exists?(id: params[:team_id])

    raise ArgumentError, "Invalid communication thread team_id: #{params[:team_id]}"
  end

  def render_communication_thread_parameter_error(error)
    render_could_not_create_error(error.message)
  end

  def render_status_reason_error(error)
    render json: { error: error.message, code: error.code, details: error.details }, status: error.status
  end

  def ensure_communication_threads_feature_enabled!
    return if Current.account&.feature_enabled?(FEATURE_NAME)

    render json: { error: 'Communication threads feature is disabled' }, status: :forbidden
  end

  def ensure_thread_accessible!
    return if accessible_links_for(@communication_thread).exists?

    raise ActiveRecord::RecordNotFound
  end

  def ensure_full_thread_accessible_for_update!
    return if accessible_links_for(@communication_thread).count == @communication_thread.communication_thread_conversations.count

    raise ArgumentError, 'Cannot update communication thread without access to all linked channels'
  end

  def with_list_presence_cache(&)
    OnlineStatusTracker.with_presence_cache(&)
  end

end
