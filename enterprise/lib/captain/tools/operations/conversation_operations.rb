class Captain::Tools::Operations::ConversationOperations < Captain::Tools::Operations::BaseOperation
  SINGLE_ATTACHMENT_MESSAGE_CHANNELS = %w[Channel::Whatsapp Channel::WhatsappWeb].freeze

  def add_contact_note(note:)
    raise ArgumentError, 'A contact note is required' if note.blank?
    raise ArgumentError, 'Current contact is not available' if current_contact.blank?

    current_contact.notes.create!(content: note.to_s.strip)
  end

  def add_label(label_name:, conversation_id: nil)
    raise ArgumentError, 'A label name is required' if label_name.blank?

    target_conversation = resolve_conversation!(conversation_id)

    label = account.labels.find_by(title: label_name.to_s.strip.downcase)
    raise ArgumentError, 'Label not found' if label.blank?

    target_conversation.add_labels(label.title)
    target_conversation.reload
  end

  def remove_label(label_name:, conversation_id: nil)
    raise ArgumentError, 'A label name is required' if label_name.blank?

    target_conversation = resolve_conversation!(conversation_id)

    normalized_label = label_name.to_s.strip.downcase
    labels = target_conversation.label_list.to_a - [normalized_label]
    target_conversation.update!(label_list: labels)
    target_conversation.reload
  end

  def add_private_note(note:, conversation_id: nil)
    raise ArgumentError, 'A private note is required' if note.blank?

    target_conversation = resolve_conversation!(conversation_id)

    target_conversation.messages.create!(
      account: account,
      inbox: target_conversation.inbox,
      sender: assistant,
      message_type: :outgoing,
      content: note.to_s.strip,
      private: true
    )
  end

  def send_message_to_conversation(
    conversation_id: nil,
    communication_thread_id: nil,
    channel_key: nil,
    target_inbox_id: nil,
    target_contact_inbox_id: nil,
    content: nil,
    content_kind: nil,
    template_params: nil,
    private_note: false,
    in_reply_to_message_id: nil,
    attachment_ids: [],
    artifact_ids: []
  )
    if communication_thread_target?(
      communication_thread_id: communication_thread_id,
      channel_key: channel_key,
      target_inbox_id: target_inbox_id,
      target_contact_inbox_id: target_contact_inbox_id
    )
      return send_message_to_communication_thread(
        conversation_id: conversation_id,
        communication_thread_id: communication_thread_id,
        channel_key: channel_key,
        target_inbox_id: target_inbox_id,
        target_contact_inbox_id: target_contact_inbox_id,
        content: content,
        content_kind: content_kind,
        template_params: template_params,
        private_note: private_note,
        in_reply_to_message_id: in_reply_to_message_id,
        attachment_ids: attachment_ids,
        artifact_ids: artifact_ids
      )
    end

    target_conversation = find_permissible_conversation!(conversation_id)
    sanitized_content = content.to_s.strip
    selected_attachment_ids = materialized_attachment_ids(attachment_ids: attachment_ids, artifact_ids: artifact_ids)
    normalized_template_params = parsed_hash(template_params, field_name: 'template_params')
    normalized_content_kind = normalized_content_kind(content_kind, template_params: normalized_template_params)
    private_message = ActiveModel::Type::Boolean.new.cast(private_note)

    validate_message_payload!(
      content: sanitized_content,
      content_kind: normalized_content_kind,
      template_params: normalized_template_params,
      attachments: selected_attachment_ids,
      private_note: private_message
    )

    delivery_policy = ::Outbound::DeliveryPolicy.ensure!(
      conversation: target_conversation,
      content_kind: normalized_content_kind,
      template_params: normalized_template_params,
      attachments: selected_attachment_ids,
      private_note: private_message
    )

    if split_outgoing_attachments?(
      conversation: target_conversation,
      content_kind: normalized_content_kind,
      private_message: private_message,
      attachments: selected_attachment_ids
    )
      return create_split_attachment_messages(
        conversation: target_conversation,
        content: sanitized_content,
        attachment_ids: selected_attachment_ids,
        in_reply_to_message_id: in_reply_to_message_id,
        delivery_policy: delivery_policy
      )
    end

    create_delivery_message(
      conversation: target_conversation,
      message_options: {
        content: sanitized_content.presence,
        private_message: private_message,
        attachments: selected_attachment_ids,
        template_params: normalized_template_params,
        content_kind: normalized_content_kind,
        in_reply_to_message_id: in_reply_to_message_id
      },
      delivery_policy: delivery_policy
    )
  end

  def edit_message(message_id:, content:)
    message = find_permissible_message!(message_id)
    sanitized_content = content.to_s.strip
    raise ArgumentError, 'Message content is required' if sanitized_content.blank?

    ::Messages::UpdateContentService.new(message: message, content: sanitized_content).perform
  end

  def retry_failed_message(message_id:)
    message = find_permissible_message!(message_id)
    raise ArgumentError, 'Only outgoing messages can be retried' unless message.outgoing?
    raise ArgumentError, 'Only failed messages can be retried' unless message.failed?

    ::Messages::StatusUpdateService.new(message, 'sent').perform
    message.update!(content_attributes: {})
    ::SendReplyJob.perform_later(message.id)
    message.reload
  end

  def assign_conversation(conversation_id:, assignee_id: nil, assignee_type: nil, team_id: nil)
    target_conversation = find_permissible_conversation!(conversation_id)

    if assignee_id.present? || assignee_type.present?
      ::Conversations::AssignmentService.new(
        conversation: target_conversation,
        assignee_id: assignee_id,
        assignee_type: assignee_type
      ).perform
    end

    unless team_id.nil?
      team = team_id.present? ? account.teams.find(team_id) : nil
      target_conversation.update!(team: team)
    end

    target_conversation.reload
  end

  def handoff(reason: nil, status_reason: nil)
    raise ArgumentError, 'Current conversation is not available' if conversation.blank?

    add_private_note(note: reason) if reason.present?
    conversation.bot_handoff!(
      status_reason: configured_status_reason_for(conversation, 'open', status_reason, fallback_reason: reason),
      actor: actor || assistant,
      source: captain_status_source
    )
    ::MessageTemplates::Template::OutOfOffice.perform_if_applicable(conversation) unless conversation.campaign.present?
    conversation.reload
  end

  def resolve_conversation(reason: nil, status_reason: nil)
    raise ArgumentError, 'Current conversation is not available' if conversation.blank?
    raise ArgumentError, 'Conversation is already resolved' if conversation.resolved?
    raise ArgumentError, 'Auto-resolve is disabled for this account' if conversation.account.captain_auto_resolve_disabled?

    params = { status: 'resolved' }
    status_reason = configured_status_reason_for(conversation, 'resolved', status_reason, fallback_reason: reason)
    params[:status_reason] = status_reason if status_reason.present?

    transition = lambda do
      ::Conversations::StatusTransitionService.new(
        conversation: conversation,
        params: params,
        actor: actor || assistant,
        source: captain_status_source
      ).perform
    end

    if reason.present?
      conversation.with_captain_activity_context(reason: reason, reason_type: :tool, &transition)
    else
      transition.call
    end
    conversation.reload
  end

  def update_priority(priority:)
    raise ArgumentError, 'Current conversation is not available' if conversation.blank?

    normalized_priority = priority.to_s.strip
    normalized_priority = nil if normalized_priority.blank? || normalized_priority == 'none'
    unless normalized_priority.nil? || Conversation.priorities.key?(normalized_priority)
      raise ArgumentError, "priority must be one of: #{Conversation.priorities.keys.join(', ')}"
    end

    conversation.update!(priority: normalized_priority)
    conversation.reload
  end

  private

  def permissible_conversations
    ::Conversations::PermissionFilterService.new(account.conversations, actor, account).perform
  end

  def materialized_attachment_ids(attachment_ids:, artifact_ids:)
    attachment_resolver.resolve(attachment_ids: attachment_ids, artifact_ids: artifact_ids)
  end

  def communication_thread_target?(communication_thread_id:, channel_key:, target_inbox_id:, target_contact_inbox_id:)
    communication_thread_id.present? || channel_key.present? || target_inbox_id.present? || target_contact_inbox_id.present?
  end

  def send_message_to_communication_thread(
    conversation_id: nil,
    communication_thread_id: nil,
    channel_key: nil,
    target_inbox_id: nil,
    target_contact_inbox_id: nil,
    content: nil,
    content_kind: nil,
    template_params: nil,
    private_note: false,
    in_reply_to_message_id: nil,
    attachment_ids: [],
    artifact_ids: []
  )
    communication_thread = find_permissible_communication_thread!(communication_thread_id)
    sanitized_content = content.to_s.strip
    selected_attachment_ids = materialized_attachment_ids(attachment_ids: attachment_ids, artifact_ids: artifact_ids)
    normalized_template_params = parsed_hash(template_params, field_name: 'template_params')
    normalized_content_kind = normalized_content_kind(content_kind, template_params: normalized_template_params)
    private_message = ActiveModel::Type::Boolean.new.cast(private_note)

    validate_message_payload!(
      content: sanitized_content,
      content_kind: normalized_content_kind,
      template_params: normalized_template_params,
      attachments: selected_attachment_ids,
      private_note: private_message
    )

    params = delivery_message_params(
      content: sanitized_content.presence,
      private_message: private_message,
      attachments: selected_attachment_ids,
      template_params: normalized_template_params,
      content_kind: normalized_content_kind,
      in_reply_to_message_id: in_reply_to_message_id
    )
    params[:conversation_id] = conversation_id if conversation_id.present?
    params[:channel_key] = channel_key.to_s.strip if channel_key.present?
    params[:target_inbox_id] = target_inbox_id if target_inbox_id.present?
    params[:target_contact_inbox_id] = target_contact_inbox_id if target_contact_inbox_id.present?
    params[:content_kind] = normalized_content_kind

    with_current_account_context do
      ::CommunicationThreads::MessageCreateService.new(
        communication_thread: communication_thread,
        current_user: actor,
        params: ActionController::Parameters.new(params),
        accessible_inboxes: accessible_inboxes_for_actor,
        accessible_links: accessible_communication_thread_links(communication_thread)
      ).perform
    end
  end

  def split_outgoing_attachments?(conversation:, content_kind:, private_message:, attachments:)
    !private_message &&
      content_kind == 'free_text' &&
      Array(attachments).many? &&
      SINGLE_ATTACHMENT_MESSAGE_CHANNELS.include?(conversation.inbox.channel_type)
  end

  def create_split_attachment_messages(conversation:, content:, attachment_ids:, in_reply_to_message_id:, delivery_policy:)
    first_attachment_id, *remaining_attachment_ids = Array(attachment_ids)
    first_message = create_split_attachment_message(conversation, delivery_policy, first_attachment_id, content.presence, in_reply_to_message_id)

    remaining_attachment_ids.each do |attachment_id|
      create_split_attachment_message(conversation, delivery_policy, attachment_id, nil, nil)
    end

    first_message
  end

  def create_split_attachment_message(conversation, delivery_policy, attachment_id, content, in_reply_to_message_id)
    create_delivery_message(
      conversation: conversation,
      message_options: {
        content: content,
        private_message: false,
        attachments: [attachment_id],
        template_params: {},
        content_kind: 'free_text',
        in_reply_to_message_id: in_reply_to_message_id
      },
      delivery_policy: delivery_policy
    )
  end

  def create_delivery_message(conversation:, message_options:, delivery_policy: nil)
    params = delivery_message_params(message_options)
    message = ::Messages::MessageBuilder.new(actor, conversation, params.compact).perform
    annotate_delivery_policy!(message, delivery_policy) if delivery_policy.present?
    message
  end

  def delivery_message_params(message_options)
    params = {
      content: message_options[:content],
      private: message_options[:private_message],
      attachments: message_options[:attachments]
    }
    params[:template_params] = message_options[:template_params] if message_options[:content_kind] == 'channel_template'
    in_reply_to_message_id = message_options[:in_reply_to_message_id]
    params[:content_attributes] = { in_reply_to: in_reply_to_message_id } if in_reply_to_message_id.present?
    params
  end

  def attachment_resolver
    @attachment_resolver ||= Captain::Tools::AttachmentResolver.new(account: account, assistant: assistant)
  end

  def normalized_content_kind(content_kind, template_params:)
    normalized = content_kind.to_s.strip
    return normalized if normalized.present?
    return 'channel_template' if template_params.present?

    'free_text'
  end

  def validate_message_payload!(content:, content_kind:, template_params:, attachments:, private_note:)
    if private_note
      raise ArgumentError, 'Private notes cannot use channel templates' if content_kind == 'channel_template' || template_params.present?
      raise ArgumentError, 'Message content or attachment is required' if content.blank? && attachments.blank?

      return
    end

    case content_kind
    when 'channel_template'
      raise ArgumentError, 'template_params are required for channel_template messages' if template_params.blank?
    when 'free_text'
      raise ArgumentError, 'Message content or attachment is required' if content.blank? && attachments.blank?
    else
      raise ArgumentError, 'content_kind must be one of: free_text, channel_template'
    end
  end

  def annotate_delivery_policy!(message, delivery_policy)
    return message if message.private?

    message.update!(
      additional_attributes: (message.additional_attributes || {}).merge(
        'delivery_policy' => delivery_policy.as_json
      )
    )
  end

  def find_permissible_communication_thread!(communication_thread_id)
    raise ArgumentError, 'Communication threads feature is disabled' unless account.feature_enabled?('communication_threads')

    thread = if communication_thread_id.present?
               CommunicationThread.find_by(account_id: account.id, display_id: communication_thread_id) ||
                 CommunicationThread.find_by(account_id: account.id, id: communication_thread_id)
             else
               conversation&.communication_thread || conversation&.reload&.communication_thread
             end
    raise ActiveRecord::RecordNotFound, 'Communication thread not found' if thread.blank? || thread.account_id != account.id

    return thread if thread.communication_thread_conversations.exists?(conversation_id: permissible_conversations.select(:id))

    raise ActiveRecord::RecordNotFound, 'Communication thread not found'
  end

  def accessible_inboxes_for_actor
    inboxes = account.inboxes.includes(:channel)
    return inboxes if actor_account_user&.administrator?
    return inboxes.none if actor.blank?

    inboxes.where(id: actor.inboxes.where(account_id: account.id).select(:id))
  end

  def accessible_communication_thread_links(communication_thread)
    communication_thread.communication_thread_conversations.where(conversation_id: permissible_conversations.select(:id))
  end

  def actor_account_user
    return if actor.blank?

    @actor_account_user ||= AccountUser.find_by(account_id: account.id, user_id: actor.id)
  end

  def configured_status_reason_for(target_conversation, target_status, explicit_reason, fallback_reason: nil)
    config = ::Conversations::StatusReasonConfig.new(target_conversation.account)
    explicit_reason = explicit_reason.to_s.strip.presence
    return config.resolve_reason!(target_status, explicit_reason, enforce_required: false) if explicit_reason.present?

    config.canonical_reason(target_status, fallback_reason)
  end

  def captain_status_source
    actor.present? ? 'copilot' : 'captain'
  end

  def with_current_account_context
    previous_account = Current.account
    previous_account_user = Current.account_user
    previous_user = Current.user
    Current.account = account
    Current.account_user = actor_account_user
    Current.user = actor
    yield
  ensure
    Current.account = previous_account
    Current.account_user = previous_account_user
    Current.user = previous_user
  end

  def find_permissible_conversation!(conversation_id)
    permissible_conversations.find_by(display_id: conversation_id) ||
      permissible_conversations.find_by(id: conversation_id) ||
      raise(ActiveRecord::RecordNotFound, 'Conversation not found')
  end

  def resolve_conversation!(conversation_id = nil)
    return find_permissible_conversation!(conversation_id) if conversation_id.present?
    raise ArgumentError, 'Current conversation is not available' if conversation.blank?

    conversation
  end

  def find_permissible_message!(message_id)
    ::Message.joins(:conversation)
             .where(conversation_id: permissible_conversations.select(:id))
             .find(message_id)
  end
end
