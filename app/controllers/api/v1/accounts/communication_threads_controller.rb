class Api::V1::Accounts::CommunicationThreadsController < Api::V1::Accounts::BaseController
  FEATURE_NAME = 'communication_threads'.freeze
  JSON_MESSAGE_PARAMS = %i[content_attributes template_params delivery_policy].freeze
  ATTACHMENT_RESULTS_PER_PAGE = 100
  MEMBER_THREAD_ACTIONS = [:show, :update, :messages, :channels, :attachments, :labels, :update_labels, :create_message, :update_last_seen].freeze

  rescue_from CommunicationThreadFinder::InvalidParameter, with: :render_communication_thread_parameter_error
  rescue_from CommunicationThreads::MessageCreateService::Error, with: :render_communication_thread_parameter_error
  rescue_from ArgumentError, with: :render_communication_thread_parameter_error

  before_action :ensure_communication_threads_feature_enabled!
  before_action :communication_thread, only: MEMBER_THREAD_ACTIONS
  before_action :ensure_thread_accessible!, only: MEMBER_THREAD_ACTIONS
  before_action :ensure_full_thread_accessible_for_update!, only: [:update]
  before_action :validate_update_params!, only: [:update]

  def index
    result = CommunicationThreadFinder.new(Current.user, params).perform
    @communication_threads = result[:communication_threads]
    @communication_threads_count = result[:count]
    preload_accessible_links(@communication_threads)
  end

  def meta
    result = CommunicationThreadFinder.new(Current.user, params).perform_meta_only

    render json: { meta: result[:count] }
  end

  def show
    preload_accessible_links([@communication_thread], include_unlinked: true)
  end

  def update
    @communication_thread = CommunicationThreads::UpdateService.new(
      communication_thread: @communication_thread,
      params: permitted_update_params,
      accessible_links: accessible_links_for(@communication_thread)
    ).perform
    preload_accessible_links([@communication_thread], include_unlinked: true)
    render :show
  end

  def channels
    preload_accessible_links([@communication_thread], include_unlinked: true)
  end

  def messages
    preload_accessible_links([@communication_thread], include_unlinked: true)
    @messages = CommunicationThreadMessageFinder.new(
      communication_thread: @communication_thread,
      current_user: Current.user,
      params: params
    ).perform
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
                             .order(created_at: :desc)
                             .page(attachment_params[:page])
                             .per(ATTACHMENT_RESULTS_PER_PAGE)
  end

  def labels
    @labels = thread_label_list
  end

  def update_labels
    label_values = permitted_label_params[:labels] || []
    accessible_links_for(@communication_thread).includes(:conversation).find_each do |link|
      link.conversation.update_labels(label_values)
    end
    @labels = label_values
    render :labels
  end

  def create_message
    @message = CommunicationThreads::MessageCreateService.new(
      communication_thread: @communication_thread,
      current_user: Current.user,
      params: permitted_message_params,
      accessible_inboxes: accessible_inboxes,
      accessible_links: accessible_links_for(@communication_thread)
    ).perform
    preload_accessible_links([@communication_thread], include_unlinked: true)
    render :message
  end

  def update_last_seen
    @communication_thread = CommunicationThreads::MarkReadService.new(
      communication_thread: @communication_thread,
      current_user: Current.user,
      current_account: Current.account,
      accessible_links: accessible_links_for(@communication_thread)
    ).perform
    preload_accessible_links([@communication_thread], include_unlinked: true)
    render :show
  end

  private

  def communication_thread
    @communication_thread = CommunicationThread.find_by!(account_id: Current.account.id, display_id: params[:id])
  end

  def permitted_update_params
    params.permit(:status, :priority, :assignee_id, :assignee_type, :team_id, :snoozed_until)
  end

  def attachment_params
    params.permit(:page)
  end

  def permitted_label_params
    params.permit(:id, labels: [])
  end

  def thread_label_list
    accessible_links_for(@communication_thread)
      .includes(:conversation)
      .flat_map { |link| link.conversation.label_list }
      .uniq
  end

  def permitted_message_params
    normalized_message_params.permit(
      :content,
      :private,
      :echo_id,
      :content_type,
      :message_type,
      :source_id,
      :conversation_id,
      :inbox_id,
      :target_inbox_id,
      :contact_inbox_id,
      :target_contact_inbox_id,
      :channel_key,
      :content_kind,
      :cc_emails,
      :bcc_emails,
      :to_emails,
      :email_html_content,
      :preserve_waiting_since,
      attachments: [],
      content_attributes: {},
      template_params: {},
      delivery_policy: {}
    )
  end

  def normalized_message_params
    raw_params = params.to_unsafe_h
    JSON_MESSAGE_PARAMS.each { |key| normalize_json_message_param!(raw_params, key) }
    ActionController::Parameters.new(raw_params)
  end

  def normalize_json_message_param!(raw_params, key)
    value = raw_params[key.to_s] || raw_params[key]
    return unless value.is_a?(String)

    parsed_value = JSON.parse(value)
    raw_params[key.to_s] = parsed_value if parsed_value.is_a?(Hash)
  rescue JSON::ParserError
    nil
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
    return if %w[User AgentBot].include?(params[:assignee_type].to_s)

    raise ArgumentError, "Invalid communication thread assignee_type: #{params[:assignee_type]}"
  end

  def validate_assignee!
    return unless params.key?(:assignee_id) && params[:assignee_id].present?

    if params[:assignee_type].to_s == 'AgentBot'
      return if AgentBot.accessible_to(Current.account).exists?(id: params[:assignee_id])

      raise ArgumentError, "Invalid communication thread assignee_id: #{params[:assignee_id]}"
    end
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

  def preload_accessible_links(communication_threads, include_unlinked: false)
    thread_ids = communication_threads.map(&:id)
    @accessible_links_by_thread_id = if thread_ids.empty?
                                       {}
                                     else
                                       accessible_links.where(communication_thread_id: thread_ids)
                                                       .includes({ contact_inbox: :channel_profile }, :conversation, inbox: :channel)
                                                       .group_by(&:communication_thread_id)
                                     end
    @channel_capabilities_by_thread_id = @accessible_links_by_thread_id.transform_values do |links|
      CommunicationThreads::ChannelCapabilitiesBuilder.new(
        links: links,
        available_inboxes: accessible_inboxes,
        include_unlinked: include_unlinked,
        preferred_status: preferred_channel_status
      ).perform
    end
    preload_last_public_messages_by_thread
  end

  def preload_last_public_messages_by_thread
    links = @accessible_links_by_thread_id.values.flatten
    conversation_ids = links.map(&:conversation_id)
    @last_public_messages_by_thread_id = {}
    return if conversation_ids.empty?

    last_messages_by_conversation_id = Message
                                       .where(
                                         account_id: Current.account.id,
                                         conversation_id: conversation_ids,
                                         private: false
                                       )
                                       .select('DISTINCT ON (messages.conversation_id) messages.*')
                                       .reorder(Arel.sql('messages.conversation_id, messages.created_at DESC, messages.id DESC'))
                                       .index_by(&:conversation_id)

    @last_public_messages_by_thread_id = @accessible_links_by_thread_id.transform_values do |thread_links|
      thread_links.filter_map { |link| last_messages_by_conversation_id[link.conversation_id] }
                  .max_by { |message| [message.created_at, message.id] }
    end
  end

  def accessible_links_for(thread)
    accessible_links.where(communication_thread_id: thread.id)
  end

  def accessible_links
    CommunicationThreadConversation.where(
      account_id: Current.account.id,
      conversation_id: accessible_conversations.select(:id)
    )
  end

  def accessible_conversations
    @accessible_conversations ||= Conversations::PermissionFilterService.new(
      Current.account.conversations,
      Current.user,
      Current.account
    ).perform
  end

  def accessible_inboxes
    @accessible_inboxes ||= begin
      inboxes = Current.account.inboxes.includes(:channel)
      Current.account_user&.administrator? ? inboxes : inboxes.where(id: Current.user.inboxes.where(account_id: Current.account.id).select(:id))
    end
  end

  def preferred_channel_status
    return if params[:status].blank? || params[:status] == 'all'
    return unless CommunicationThread.statuses.key?(params[:status].to_s)

    params[:status].to_s
  end
end
