class Api::V1::Accounts::CommunicationThreadsController < Api::V1::Accounts::BaseController
  FEATURE_NAME = 'communication_threads'.freeze
  JSON_MESSAGE_PARAMS = %i[content_attributes template_params delivery_policy].freeze
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
  rescue_from CommunicationThreads::MessageCreateService::Error, with: :render_communication_thread_parameter_error
  rescue_from Conversations::StatusReasonConfig::Error, with: :render_status_reason_error
  rescue_from ArgumentError, with: :render_communication_thread_parameter_error

  before_action :ensure_communication_threads_feature_enabled!
  before_action :communication_thread, only: MEMBER_THREAD_ACTIONS
  before_action :ensure_thread_accessible!, only: MEMBER_THREAD_ACTIONS
  before_action :ensure_full_thread_accessible_for_update!, only: [:update]
  before_action :validate_update_params!, only: [:update]
  around_action :with_list_presence_cache, only: [:index, :filter]

  def index
    result = CommunicationThreadFinder.new(Current.user, params).perform
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
    preload_accessible_links([@communication_thread], include_unlinked: true)
  end

  def messages
    preload_accessible_links([@communication_thread], include_unlinked: true)
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
                             .order(created_at: :desc)
                             .page(attachment_params[:page])
                             .per(ATTACHMENT_RESULTS_PER_PAGE)
  end

  def labels
    @labels = thread_label_list
  end

  def update_labels
    label_values = permitted_label_params[:labels] || []
    conversations = accessible_links_for(@communication_thread).includes(:conversation).map(&:conversation)
    @labels = Labels::UnifiedAssignmentService.new(
      contact: @communication_thread.contact,
      conversations: conversations,
      labels: label_values
    ).perform
    render :labels
  end

  def destroy_conversations
    conversations = selected_delete_conversations
    authorize_delete_conversations!(conversations)
    enqueue_delete_conversations(conversations)

    render json: {
      thread_id: @communication_thread.display_id,
      deleted_conversation_ids: conversations.map(&:display_id)
    }, status: :accepted
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
    render json: {
      id: @communication_thread.display_id,
      unread_count: @communication_thread.unread_count,
      agent_last_seen_at: service.last_seen_at&.to_i,
      channels: service.channel_read_states
    }
  end

  def unread
    @communication_thread = CommunicationThreads::MarkUnreadService.new(
      communication_thread: @communication_thread,
      accessible_links: accessible_links_for(@communication_thread)
    ).perform
    preload_accessible_links([@communication_thread], include_unlinked: true)
    preload_crm_deal_stages([@communication_thread])
    preload_meta_ad_referrals([@communication_thread])
    render :show
  end

  private

  def communication_thread
    @communication_thread = CommunicationThread.find_by!(account_id: Current.account.id, display_id: params[:id])
  end

  def first_unread_message_id_for(communication_thread)
    conversation_ids = accessible_links_for(communication_thread).select(:conversation_id)

    messages = Message.joins(:conversation)
                      .where(
                        account_id: Current.account.id,
                        conversation_id: conversation_ids,
                        message_type: Message.message_types[:incoming],
                        private: false
                      )
                      .where('messages.created_at > COALESCE(conversations.agent_last_seen_at, ?)', Time.zone.at(0))
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
    params.permit(:id, labels: [])
  end

  def permitted_delete_conversation_ids
    raw_ids = Array(params[:conversation_ids])
    raise ArgumentError, 'Select at least one communication thread conversation' if raw_ids.blank?

    raw_ids.map { |conversation_id| Integer(conversation_id) }.uniq
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

  def enqueue_delete_conversations(conversations)
    conversations.each { |conversation| DeleteObjectJob.perform_later(conversation, Current.user, request.ip) }
  end

  def thread_label_list
    conversations = accessible_links_for(@communication_thread)
                    .includes(:conversation)
                    .map(&:conversation)
    Labels::UnifiedAssignmentService.union_for(
      contact: @communication_thread.contact,
      conversations: conversations
    )
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

  def preload_accessible_links(communication_threads, include_unlinked: false)
    @communication_threads_by_id = communication_threads.index_by(&:id)
    thread_ids = communication_threads.map(&:id)
    @accessible_links_by_thread_id = preloaded_accessible_links(thread_ids)
    preload_channel_message_state
    preload_channel_capabilities(include_unlinked)
    preload_last_public_messages_by_thread
    preload_last_non_activity_messages_by_thread
    preload_list_message_associations
    preload_thread_labels(communication_threads)
    preload_directional_message_timestamps_by_thread
    preload_scheduling_appointment_statuses(communication_threads)
    preload_list_presence(communication_threads) if OnlineStatusTracker.presence_cache
  end

  def with_list_presence_cache(&)
    OnlineStatusTracker.with_presence_cache(&)
  end

  def preload_list_presence(communication_threads)
    messages = [@last_public_messages_by_thread_id, @last_non_activity_messages_by_thread_id].flat_map(&:values).compact
    senders = messages.filter_map(&:sender).group_by(&:class)
    preload_contact_and_user_presence(communication_threads, senders)
  end

  def preload_contact_and_user_presence(communication_threads, senders)
    contacts = communication_threads.map(&:contact) + senders.fetch(Contact, [])
    users = communication_threads.filter_map(&:assignee) + contacts.filter_map(&:owner) +
            senders.fetch(User, [])

    OnlineStatusTracker.preload_presence(Current.account.id, 'Contact', contacts.map(&:id))
    OnlineStatusTracker.preload_presence(Current.account.id, 'User', users.map(&:id))
  end

  def preloaded_accessible_links(thread_ids)
    return {} if thread_ids.empty?

    accessible_links.where(communication_thread_id: thread_ids)
                    .includes(
                      { contact_inbox: :channel_profile },
                      { conversation: { inbox: :channel } },
                      { inbox: [:members, :channel] }
                    )
                    .group_by(&:communication_thread_id)
  end

  def preload_channel_capabilities(include_unlinked)
    @channel_capabilities_by_thread_id = @accessible_links_by_thread_id.transform_values do |links|
      CommunicationThreads::ChannelCapabilitiesBuilder.new(
        links: links,
        contact: @communication_threads_by_id[links.first.communication_thread_id]&.contact,
        available_inboxes: accessible_inboxes,
        include_unlinked: include_unlinked,
        preferred_status: preferred_channel_status,
        unread_counts: @channel_unread_counts_by_conversation_id,
        last_incoming_message_timestamps: @last_incoming_message_timestamps_by_conversation_id
      ).perform
    end
  end

  def preload_crm_deal_stages(communication_threads)
    @crm_deal_stages_by_communication_thread_id =
      Crm::DealDialogStageContextBuilder.new(account: Current.account).for_communication_threads(communication_threads)
  end

  def preload_scheduling_appointment_statuses(communication_threads)
    @scheduling_appointment_statuses_by_communication_thread_id =
      Scheduling::AppointmentDialogStatusContextBuilder.new(account: Current.account).for_communication_threads(communication_threads)
  end

  def preload_meta_ad_referrals(communication_threads)
    thread_ids = communication_threads.map(&:id)
    accessible_conversation_ids = (@accessible_links_by_thread_id || {}).values.flatten.filter_map(&:conversation_id)
    @meta_ad_referrals_by_communication_thread_id = if thread_ids.empty? || accessible_conversation_ids.empty?
                                                      {}
                                                    else
                                                      MetaAdReferral
                                                        .where(
                                                          account_id: Current.account.id,
                                                          communication_thread_id: thread_ids,
                                                          conversation_id: accessible_conversation_ids
                                                        )
                                                        .select('DISTINCT ON (communication_thread_id) meta_ad_referrals.*')
                                                        .reorder(Arel.sql('communication_thread_id, received_at DESC, id DESC'))
                                                        .index_by(&:communication_thread_id)
                                                    end
  end

  def preload_last_public_messages_by_thread
    @last_public_messages_by_thread_id = preload_last_messages_by_thread
  end

  def preload_channel_message_state
    conversation_ids = @accessible_links_by_thread_id.values.flatten.map(&:conversation_id).uniq
    return reset_channel_message_state if conversation_ids.empty?

    incoming_messages = incoming_channel_messages(conversation_ids)
    @last_incoming_message_timestamps_by_conversation_id = incoming_messages.group(:conversation_id).maximum(:created_at)
    @channel_unread_counts_by_conversation_id = unread_channel_message_counts(incoming_messages)
  end

  def reset_channel_message_state
    @channel_unread_counts_by_conversation_id = {}
    @last_incoming_message_timestamps_by_conversation_id = {}
  end

  def incoming_channel_messages(conversation_ids)
    Message.reorder(nil).where(
      account_id: Current.account.id,
      conversation_id: conversation_ids,
      message_type: Message.message_types[:incoming]
    )
  end

  def unread_channel_message_counts(incoming_messages)
    incoming_messages.where(private: false)
                     .joins(:conversation)
                     .where(
                       'messages.created_at > COALESCE(conversations.agent_last_seen_at, ?)',
                       Time.zone.at(0)
                     )
                     .group(:conversation_id)
                     .count
  end

  def preload_last_non_activity_messages_by_thread
    @last_non_activity_messages_by_thread_id = preload_last_messages_by_thread(non_activity: true)
  end

  def preload_list_message_associations
    messages = [@last_public_messages_by_thread_id, @last_non_activity_messages_by_thread_id]
               .flat_map(&:values)
               .compact
    return if messages.empty?

    ActiveRecord::Associations::Preloader.new(
      records: messages,
      associations: [
        { attachments: { file_attachment: :blob } },
        :sender,
        { inbox: :channel },
        { conversation: [{ contact_inbox: :channel_profile }, :communication_thread, :campaign] }
      ]
    ).call
    preload_list_message_senders(messages)
  end

  def preload_list_message_senders(messages)
    contact_senders = messages.filter_map { |message| message.sender if message.sender.is_a?(Contact) }.uniq
    user_senders = messages.filter_map { |message| message.sender if message.sender.is_a?(User) }.uniq
    if contact_senders.any?
      ActiveRecord::Associations::Preloader.new(
        records: contact_senders,
        associations: [:contact_channel_profiles, { avatar_attachment: :blob }, { owner: { avatar_attachment: :blob } }]
      ).call
    end
    return unless user_senders.any?

    ActiveRecord::Associations::Preloader.new(
      records: user_senders,
      associations: { avatar_attachment: :blob }
    ).call
  end

  def preload_thread_labels(communication_threads)
    contact_labels = label_names_by_record('Contact', communication_threads.map(&:contact_id))
    conversation_labels = label_names_by_record(
      'Conversation',
      @accessible_links_by_thread_id.values.flatten.map(&:conversation_id)
    )

    @labels_by_thread_id = communication_threads.each_with_object({}) do |thread, labels_by_thread_id|
      linked_labels = @accessible_links_by_thread_id.fetch(thread.id, []).flat_map do |link|
        conversation_labels.fetch(link.conversation_id, [])
      end
      labels_by_thread_id[thread.id] = Labels::UnifiedAssignmentService.normalize(
        contact_labels.fetch(thread.contact_id, []) + linked_labels
      )
    end
  end

  def label_names_by_record(record_type, record_ids)
    return {} if record_ids.empty?

    ActsAsTaggableOn::Tagging
      .joins(:tag)
      .where(taggable_type: record_type, taggable_id: record_ids, context: 'labels', tagger_id: nil)
      .pluck(:taggable_id, 'tags.name')
      .group_by(&:first)
      .transform_values { |rows| rows.map(&:second) }
  end

  def preload_directional_message_timestamps_by_thread
    preloader =
      Conversations::DirectionalMessageTimestampPreloader.new(account: Current.account)
    @last_message_activity_by_thread_id =
      preloader.for_communication_threads(@accessible_links_by_thread_id)
  end

  def preload_last_messages_by_thread(non_activity: false)
    links = @accessible_links_by_thread_id.values.flatten
    conversation_ids = links.map(&:conversation_id)
    return {} if conversation_ids.empty?

    message_scope = Message.where(
      account_id: Current.account.id,
      conversation_id: conversation_ids,
      private: false
    )
    message_scope = message_scope.where.not(message_type: Message.message_types[:activity]) if non_activity

    last_messages_by_conversation_id = message_scope
                                       .select('DISTINCT ON (messages.conversation_id) messages.*')
                                       .reorder(Arel.sql('messages.conversation_id, messages.created_at DESC, messages.id DESC'))
                                       .index_by(&:conversation_id)

    @accessible_links_by_thread_id.transform_values do |thread_links|
      messages = thread_links.filter_map { |link| last_messages_by_conversation_id[link.conversation_id] }
      messages_in_current_session(messages, thread_links).max_by { |message| [message.created_at, message.id] }
    end
  end

  def messages_in_current_session(messages, thread_links)
    thread_id = thread_links.first&.communication_thread_id
    session_started_at = @communication_threads_by_id[thread_id]&.session_started_at
    return messages if session_started_at.blank?

    messages.select { |message| message.created_at >= session_started_at }
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
