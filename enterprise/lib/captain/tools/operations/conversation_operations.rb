class Captain::Tools::Operations::ConversationOperations < Captain::Tools::Operations::BaseOperation
  def add_contact_note(note:)
    raise ArgumentError, 'A contact note is required' if note.blank?
    raise ArgumentError, 'Current contact is not available' if current_contact.blank?

    current_contact.notes.create!(content: note.to_s.strip)
  end

  def add_label(label_name:)
    raise ArgumentError, 'A label name is required' if label_name.blank?
    raise ArgumentError, 'Current conversation is not available' if conversation.blank?

    label = account.labels.find_by(title: label_name.to_s.strip.downcase)
    raise ArgumentError, 'Label not found' if label.blank?

    conversation.add_labels(label.title)
    conversation.reload
  end

  def remove_label(label_name:)
    raise ArgumentError, 'A label name is required' if label_name.blank?
    raise ArgumentError, 'Current conversation is not available' if conversation.blank?

    normalized_label = label_name.to_s.strip.downcase
    labels = conversation.label_list.to_a - [normalized_label]
    conversation.update!(label_list: labels)
    conversation.reload
  end

  def add_private_note(note:)
    raise ArgumentError, 'A private note is required' if note.blank?
    raise ArgumentError, 'Current conversation is not available' if conversation.blank?

    conversation.messages.create!(
      account: account,
      inbox: conversation.inbox,
      sender: assistant,
      message_type: :outgoing,
      content: note.to_s.strip,
      private: true
    )
  end

  def send_message_to_conversation(conversation_id:, content:, private_note: false, in_reply_to_message_id: nil)
    target_conversation = find_permissible_conversation!(conversation_id)
    sanitized_content = content.to_s.strip
    raise ArgumentError, 'Message content is required' if sanitized_content.blank?

    params = {
      content: sanitized_content,
      private: ActiveModel::Type::Boolean.new.cast(private_note)
    }
    params[:content_attributes] = { in_reply_to: in_reply_to_message_id } if in_reply_to_message_id.present?

    ::Messages::MessageBuilder.new(actor, target_conversation, params).perform
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

  def find_permissible_conversation!(conversation_id)
    permissible_conversations.find_by(display_id: conversation_id) ||
      permissible_conversations.find_by(id: conversation_id) ||
      raise(ActiveRecord::RecordNotFound, 'Conversation not found')
  end

  def find_permissible_message!(message_id)
    ::Message.joins(:conversation)
             .where(conversation_id: permissible_conversations.select(:id))
             .find(message_id)
  end
end
