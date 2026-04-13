module Outbound::PayloadBuilder
  module_function

  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def touch_payload(reminder)
    {
      id: reminder.id,
      account_id: reminder.account_id,
      creator_id: reminder.creator_id,
      owner_id: reminder.owner_id,
      status: reminder.status,
      action_type: reminder.action_type,
      content_kind: reminder.content_kind,
      text_mode: reminder.text_mode,
      timing_mode: reminder.timing_mode,
      repeat_mode: reminder.repeat_mode,
      repeat_until_at: reminder.repeat_until_at,
      relative_anchor: reminder.relative_anchor,
      relative_offset_seconds: reminder.relative_offset_seconds,
      scheduled_at: reminder.scheduled_at,
      timezone: reminder.timezone,
      body: reminder.body,
      instructions: reminder.instructions,
      attachments: reminder.attachments,
      template_params: reminder.template_params,
      metadata: reminder.metadata,
      auto_cancel_on_incoming: reminder.auto_cancel_on_incoming,
      attempts_count: reminder.attempts_count,
      last_error: reminder.last_error,
      processing_started_at: reminder.processing_started_at,
      completed_at: reminder.completed_at,
      cancelled_at: reminder.cancelled_at,
      created_at: reminder.created_at,
      updated_at: reminder.updated_at,
      reminder_group_id: reminder.reminder_group_id,
      conversation_id: conversation_reference(reminder.conversation) || reminder.conversation_id,
      target: target_payload(reminder),
      remindable: remindable_payload(reminder.remindable)
    }
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

  def touch_plan_payload(reminder_group)
    {
      id: reminder_group.id,
      account_id: reminder_group.account_id,
      creator_id: reminder_group.creator_id,
      name: reminder_group.name,
      description: reminder_group.description,
      entity_kinds: reminder_group.entity_kinds,
      active: reminder_group.active,
      archived_at: reminder_group.archived_at,
      touches: reminder_group.touches.map do |definition|
        Reminders::DefinitionNormalizer.call(definition)
      end,
      created_at: reminder_group.created_at,
      updated_at: reminder_group.updated_at
    }
  end

  def remindable_payload(record)
    return if record.blank?

    {
      id: record.is_a?(Conversation) ? record.display_id : record.id,
      type: record.class.name,
      title: remindable_title(record)
    }
  end

  def remindable_title(record)
    return record.identifier if record.is_a?(Conversation)
    return record.title if record.respond_to?(:title)
    return record.client_name if record.respond_to?(:client_name)

    record.class.name
  end

  def target_payload(reminder)
    {
      inbox_id: reminder.target_inbox_id,
      contact_id: reminder.target_contact_id,
      contact_inbox_id: reminder.target_contact_inbox_id,
      conversation_id: conversation_reference(reminder.target_conversation) || reminder.target_conversation_id,
      inbox: target_inbox_payload(reminder.target_inbox),
      contact: target_contact_payload(reminder.target_contact)
    }
  end

  def conversation_reference(conversation)
    return if conversation.blank?

    conversation.display_id
  end

  def target_inbox_payload(inbox)
    return if inbox.blank?

    {
      id: inbox.id,
      name: inbox.name,
      channel_type: inbox.channel_type,
      medium: inbox.try(:medium) || inbox.try(:channel).try(:medium)
    }
  end

  def target_contact_payload(contact)
    return if contact.blank?

    {
      id: contact.id,
      name: contact.name,
      email: contact.email,
      phone_number: contact.phone_number
    }
  end
end
