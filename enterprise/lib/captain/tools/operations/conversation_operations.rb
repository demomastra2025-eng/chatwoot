class Captain::Tools::Operations::ConversationOperations < Captain::Tools::Operations::BaseOperation
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
    conversation_id:,
    content: nil,
    content_kind: nil,
    template_params: nil,
    private_note: false,
    in_reply_to_message_id: nil,
    attachment_ids: [],
    artifact_ids: []
  )
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

    params = {
      content: sanitized_content.presence,
      private: private_message,
      attachments: selected_attachment_ids
    }
    params[:template_params] = normalized_template_params if normalized_content_kind == 'channel_template'
    params[:content_attributes] = { in_reply_to: in_reply_to_message_id } if in_reply_to_message_id.present?

    message = ::Messages::MessageBuilder.new(actor, target_conversation, params.compact).perform
    annotate_delivery_policy!(message, delivery_policy)
    message
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

  def handoff(reason: nil)
    raise ArgumentError, 'Current conversation is not available' if conversation.blank?

    add_private_note(note: reason) if reason.present?
    conversation.bot_handoff!
    ::MessageTemplates::Template::OutOfOffice.perform_if_applicable(conversation) unless conversation.campaign.present?
    conversation.reload
  end

  def resolve_conversation(reason: nil)
    raise ArgumentError, 'Current conversation is not available' if conversation.blank?
    raise ArgumentError, 'Conversation is already resolved' if conversation.resolved?
    raise ArgumentError, 'Auto-resolve is disabled for this account' if conversation.account.captain_auto_resolve_disabled?

    if reason.present?
      conversation.with_captain_activity_context(reason: reason, reason_type: :tool) { conversation.resolved! }
    else
      conversation.resolved!
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
