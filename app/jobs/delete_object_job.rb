class DeleteObjectJob < ApplicationJob
  queue_as :low

  BATCH_SIZE = 5_000

  def perform(object, user = nil, ip = nil)
    deletion_context = build_post_deletion_context(object)

    mark_pending_deletion(object)
    teardown_remote_dependencies(object)
    prepare_telephony_dependencies(object)

    # Pre-purge heavy associations for large objects to avoid
    # timeouts & race conditions due to destroy_async fan-out.
    purge_heavy_associations(object)
    object.destroy!
    process_post_deletion_tasks(object, user, ip, deletion_context)
  end

  def process_post_deletion_tasks(object, user, ip, deletion_context = {}); end

  private

  def build_post_deletion_context(object)
    return {} unless object.is_a?(Inbox)

    {
      channel_medium: object.channel.try(:medium)
    }.compact
  end

  def heavy_associations
    {
      Account => %i[conversations contacts inboxes reporting_events],
      Inbox => %i[conversations contact_inboxes reporting_events]
    }.freeze
  end

  def purge_heavy_associations(object)
    klass = heavy_associations.keys.find { |k| object.is_a?(k) }
    return unless klass

    heavy_associations[klass].each do |assoc|
      next unless object.respond_to?(assoc)

      batch_destroy(object.public_send(assoc))
    end
  end

  def teardown_remote_dependencies(object)
    return unless object.is_a?(Inbox)
    return unless object.whatsapp_web? || object.telegram_personal?

    if object.whatsapp_web?
      object.channel&.teardown_provider_instance!
    elsif object.telegram_personal?
      object.channel&.teardown_runtime!
    end
  end

  def prepare_telephony_dependencies(object)
    case object
    when Inbox
      prepare_inbox_conversation_dependencies(object)
      prepare_inbox_telephony_dependencies(object)
    when Conversation
      prepare_conversation_dependencies(object.id)
      nullify_telephony_call_sessions(conversation_id: object.id)
    end
  end

  # Telephony calls are audit records. Keep sessions/events, but detach them from
  # records that are about to be removed so FK constraints cannot strand deletion.
  def prepare_inbox_telephony_dependencies(inbox)
    conversation_ids = inbox.conversations.select(:id)
    number_binding_ids = Telephony::NumberBinding.where(inbox_id: inbox.id).select(:id)

    nullify_telephony_call_sessions(conversation_id: conversation_ids)
    nullify_telephony_call_sessions(inbox_id: inbox.id)
    nullify_telephony_call_sessions(number_binding_id: number_binding_ids)
  end

  def prepare_inbox_conversation_dependencies(inbox)
    prepare_conversation_dependencies(inbox.conversations.select(:id))
    nullify_records(Reminder.where(target_inbox_id: inbox.id), target_inbox_id: nil)
    nullify_records(Reminder.where(target_contact_inbox_id: inbox.contact_inboxes.select(:id)), target_contact_inbox_id: nil)
    nullify_records(ConfirmationRequest.where(inbox_id: inbox.id), inbox_id: nil)
  end

  def prepare_conversation_dependencies(conversation_ids)
    message_ids = Message.where(conversation_id: conversation_ids).select(:id)

    nullify_records(Reminder.where(conversation_id: conversation_ids), conversation_id: nil)
    nullify_records(Reminder.where(target_conversation_id: conversation_ids), target_conversation_id: nil)
    nullify_records(Reminder.where(remindable_type: 'Conversation', remindable_id: conversation_ids), remindable_type: nil, remindable_id: nil)
    nullify_records(ConfirmationRequest.where(conversation_id: conversation_ids), conversation_id: nil)
    nullify_records(ConfirmationRequest.where(delivery_message_id: message_ids), delivery_message_id: nil)
    nullify_records(ConfirmationRequest.where(resolved_message_id: message_ids), resolved_message_id: nil)
    nullify_records(Crm::Deal.where(originating_conversation_id: conversation_ids), originating_conversation_id: nil)
    nullify_records(Crm::Task.where(originating_conversation_id: conversation_ids), originating_conversation_id: nil)
    nullify_records(Scheduling::Appointment.where(conversation_id: conversation_ids), conversation_id: nil)
  end

  def nullify_records(relation, assignments)
    attributes = assignments.merge(updated_at: Time.current)

    relation.in_batches(of: BATCH_SIZE) do |batch|
      batch.update_all(attributes) # rubocop:disable Rails/SkipsModelValidations
    end
  end

  def nullify_telephony_call_sessions(filters)
    assignments = filters.transform_values { nil }
    assignments[:updated_at] = Time.current

    Telephony::CallSession.where(filters).in_batches(of: BATCH_SIZE) do |batch|
      batch.update_all(assignments) # rubocop:disable Rails/SkipsModelValidations
    end
  end

  def mark_pending_deletion(object)
    return unless object.respond_to?(:mark_pending_deletion!)

    object.mark_pending_deletion!
  end

  def batch_destroy(relation)
    relation.find_in_batches(batch_size: BATCH_SIZE) do |batch|
      batch.each(&:destroy!)
    end
  end
end

DeleteObjectJob.prepend_mod_with('DeleteObjectJob')
