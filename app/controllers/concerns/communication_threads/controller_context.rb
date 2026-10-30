# frozen_string_literal: true

# What the controllers of the dialog of a person share: the permitted message params, what the current user may open
# (conversations, links, inboxes) and the preloads of the thread payload (channels, read state, last messages, labels, deal
# stages, appointments). Both the thread endpoints and the person endpoints (contacts/:id/dialog) render the same payload
# from them, so there is one place that decides what a user sees of a person.
module CommunicationThreads::ControllerContext
  extend ActiveSupport::Concern

  JSON_MESSAGE_PARAMS = %i[content_attributes template_params delivery_policy].freeze

  private

  # 422 { error, code, details }: the code is what the screen shows in plain words (see CommunicationThreads::MessageCreateService::Error).
  def render_message_create_error(error)
    render json: { error: sanitized_error_message(error.message), code: error.code, details: error.details }.compact,
           status: :unprocessable_content
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

  def preload_accessible_links(communication_threads, include_unlinked: false, include_list_context: true)
    @communication_threads_by_id = communication_threads.index_by(&:id)
    thread_ids = communication_threads.map(&:id)
    @accessible_links_by_thread_id = preloaded_accessible_links(thread_ids)
    preload_channel_message_state
    preload_channel_capabilities(include_unlinked)
    return unless include_list_context

    preload_list_context(communication_threads)
  end

  def preload_list_context(communication_threads)
    preload_last_public_messages_by_thread
    preload_last_non_activity_messages_by_thread
    preload_list_message_associations
    preload_thread_labels(communication_threads)
    preload_directional_message_timestamps_by_thread
    preload_scheduling_appointment_statuses(communication_threads)
    preload_list_presence(communication_threads) if OnlineStatusTracker.presence_cache
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
                      { contact_inbox: { channel_profile: { avatar_attachment: :blob } } },
                      { conversation: { inbox: :channel } },
                      { inbox: [:members, :channel] }
                    )
                    .group_by(&:communication_thread_id)
  end

  def preload_channel_capabilities(include_unlinked)
    available_inboxes = include_unlinked ? accessible_inboxes.to_a : []
    @channel_capabilities_by_thread_id = @accessible_links_by_thread_id.transform_values do |links|
      CommunicationThreads::ChannelCapabilitiesBuilder.new(
        links: links,
        contact: @communication_threads_by_id[links.first.communication_thread_id]&.contact,
        available_inboxes: available_inboxes,
        include_unlinked: include_unlinked,
        preferred_status: preferred_channel_status,
        unread_counts: @channel_unread_counts_by_conversation_id,
        last_incoming_message_timestamps: @last_incoming_message_timestamps_by_conversation_id,
        last_seen_timestamps: @channel_last_seen_timestamps_by_conversation_id
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
    accessible_conversation_ids = (@accessible_links_by_thread_id || {}).values.flatten.filter_map(&:conversation_id).uniq
    @meta_ad_referrals_by_communication_thread_id = if thread_ids.empty? || accessible_conversation_ids.empty?
                                                      {}
                                                    else
                                                      fetch_meta_ad_referrals_by_thread_id(thread_ids, accessible_conversation_ids)
                                                    end
  end

  def fetch_meta_ad_referrals_by_thread_id(thread_ids, accessible_conversation_ids)
    MetaAdReferral
      .joins(
        'INNER JOIN communication_thread_conversations ctc ' \
        'ON ctc.conversation_id = meta_ad_referrals.conversation_id ' \
        'AND ctc.account_id = meta_ad_referrals.account_id'
      )
      .where(
        account_id: Current.account.id,
        ctc: { communication_thread_id: thread_ids, conversation_id: accessible_conversation_ids }
      )
      .preload(:conversation)
      .select('DISTINCT ON (ctc.communication_thread_id) meta_ad_referrals.*, ctc.communication_thread_id AS resolved_communication_thread_id')
      .reorder(
        Arel.sql(
          'ctc.communication_thread_id, COALESCE(meta_ad_referrals.received_at, meta_ad_referrals.created_at) DESC, meta_ad_referrals.id DESC'
        )
      )
      .index_by { |referral| referral[:resolved_communication_thread_id] }
  end

  def preload_last_public_messages_by_thread
    @last_public_messages_by_thread_id = preload_last_messages_by_thread
  end

  def preload_channel_message_state
    conversation_ids = @accessible_links_by_thread_id.values.flatten.map(&:conversation_id).uniq
    return reset_channel_message_state if conversation_ids.empty?

    @last_incoming_message_timestamps_by_conversation_id = Conversations::MessageWindowService.last_incoming_timestamps(
      @accessible_links_by_thread_id.values.flatten.map(&:conversation).uniq
    )
    shared_unread_state = Conversations::SharedUnreadStatePreloader.new(
      account: Current.account,
      conversation_ids: conversation_ids
    ).perform
    @channel_last_seen_timestamps_by_conversation_id = shared_unread_state.last_seen_timestamps
    @channel_unread_counts_by_conversation_id = shared_unread_state.unread_counts
  end

  def reset_channel_message_state
    @channel_unread_counts_by_conversation_id = {}
    @last_incoming_message_timestamps_by_conversation_id = {}
    @channel_last_seen_timestamps_by_conversation_id = {}
  end

  def preload_last_non_activity_messages_by_thread
    @last_non_activity_messages_by_thread_id = {}
    activity_thread_links = {}

    @accessible_links_by_thread_id.each do |thread_id, links|
      last_public_message = @last_public_messages_by_thread_id[thread_id]
      if last_public_message&.activity?
        activity_thread_links[thread_id] = links
      else
        @last_non_activity_messages_by_thread_id[thread_id] = last_public_message
      end
    end

    return if activity_thread_links.empty?

    @last_non_activity_messages_by_thread_id.merge!(
      preload_last_messages_by_thread(non_activity: true, links_by_thread_id: activity_thread_links)
    )
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
        { conversation: [{ contact_inbox: { channel_profile: { avatar_attachment: :blob } } }, :communication_thread, :campaign] }
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
        associations: [
          { contact_channel_profiles: { avatar_attachment: :blob } }, { avatar_attachment: :blob }, { owner: { avatar_attachment: :blob } }
        ]
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

  def preload_last_messages_by_thread(non_activity: false, links_by_thread_id: @accessible_links_by_thread_id)
    links = links_by_thread_id.values.flatten
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

    links_by_thread_id.transform_values do |thread_links|
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
