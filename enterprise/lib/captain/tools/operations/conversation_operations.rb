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

  def handoff(reason: nil)
    raise ArgumentError, 'Current conversation is not available' if conversation.blank?

    add_private_note(note: reason) if reason.present?
    conversation.bot_handoff!
    ::MessageTemplates::Template::OutOfOffice.perform_if_applicable(conversation) unless conversation.campaign.present?
    conversation.reload
  end

  def resolve_conversation
    raise ArgumentError, 'Current conversation is not available' if conversation.blank?
    raise ArgumentError, 'Conversation is already resolved' if conversation.resolved?

    conversation.resolved!
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
end
