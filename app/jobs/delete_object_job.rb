class DeleteObjectJob < ApplicationJob # rubocop:disable Metrics/ClassLength -- keep this job's deletion lifecycle and retry contract together
  queue_as :low

  BATCH_SIZE = 5_000

  def perform(object, user = nil, ip = nil, deletion_attempt_id = nil)
    return perform_inbox_deletion(object, user, ip, deletion_attempt_id) if object.is_a?(Inbox)

    deletion_context = build_post_deletion_context(object)
    mark_pending_deletion(object)
    teardown_remote_dependencies(object)
    destroy_with_prepared_dependencies(object)
    process_post_deletion_tasks(object, user, ip, deletion_context)
  end

  def process_post_deletion_tasks(_object, _user, _ip, deletion_context = {})
    cleanup_empty_communication_threads(deletion_context[:communication_thread_ids])
  end

  private

  # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity -- keep generation checks adjacent to the destructive boundary.
  def perform_inbox_deletion(inbox, user, ip, requested_attempt_id)
    # Serialize each inbox's lifecycle without adding an enclosing transaction.
    # A waiting duplicate must re-read state after acquiring the advisory lock.
    Whatsapp::WabaLock.new("inbox-deletion-#{inbox.id}").with_lock do
      begin
        inbox.reload
      rescue ActiveRecord::RecordNotFound
        next nil
      end
      attempt_id = prepare_inbox_deletion_attempt(inbox, requested_attempt_id)
      tracked_attempt = whatsapp_deletion_attempt_tracked?(inbox)
      return if tracked_attempt && (attempt_id.blank? || !inbox.deletion_intent_active?(attempt_id))
      return if requested_attempt_id.present? && !inbox.deleting?

      deletion_context = build_post_deletion_context(inbox)
      mark_pending_deletion(inbox, attempt_id: attempt_id)

      if inbox.whatsapp_cloud_channel?
        teardown_result = teardown_whatsapp_inbox(inbox, attempt_id)
        return unless teardown_result == :success
      else
        teardown_remote_dependencies(inbox)
      end

      destroy_with_prepared_dependencies(inbox)
      process_post_deletion_tasks(inbox, user, ip, deletion_context)
    end
  end
  # rubocop:enable Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity -- one transition handles current, legacy, and stale attempts.
  def prepare_inbox_deletion_attempt(inbox, requested_attempt_id)
    tracked_attempt = whatsapp_deletion_attempt_tracked?(inbox)
    return requested_attempt_id unless tracked_attempt

    current_attempt_id = inbox.deletion_attempt_id
    expected_attempt_id = requested_attempt_id.presence || job_id

    if inbox.deleting?
      if current_attempt_id.present?
        return if current_attempt_id != expected_attempt_id

        return expected_attempt_id
      end

      # A legacy three-argument job can adopt only the still-active old marker.
      # An explicit stale generation must never attach itself to a new intent.
      return if requested_attempt_id.present?

      if inbox.channel_missing?
        inbox.assign_attributes(deletion_attempt_id: expected_attempt_id)
        inbox.save!(validate: false)
      else
        inbox.mark_pending_deletion!(attempt_id: expected_attempt_id)
      end
      return expected_attempt_id if inbox.deletion_intent_active?(expected_attempt_id)

      return
    end

    # WhatsApp jobs queued before the generation column existed may adopt only
    # an already-marked deletion. An active inbox, including one whose prior
    # recovery was resolved, must not be deleted by a stale nil-arg retry.
    nil
  end
  # rubocop:enable Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  def whatsapp_deletion_attempt_tracked?(inbox)
    inbox.deletion_attempt_id.present? ||
      inbox.whatsapp_cloud_channel? ||
      (inbox.channel_type == 'Channel::Whatsapp' && inbox.deleting? && inbox.channel_missing?)
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength -- validate the generation under the WABA lock before one teardown attempt.
  def teardown_whatsapp_inbox(inbox, attempt_id)
    channel = inbox.channel
    waba_id = channel.provider_config.to_h['business_account_id']
    teardown = lambda do
      inbox.reload
      next :stale unless inbox.pending_deletion_attempt?(attempt_id)

      current_channel = inbox.channel
      next :stale unless current_channel.is_a?(Channel::Whatsapp) &&
                         current_channel.provider == 'whatsapp_cloud' &&
                         current_channel.provider_config.to_h['business_account_id'] == waba_id

      begin
        teardown_remote_dependencies(inbox)
      rescue Whatsapp::WebhookTeardownService::WebhookHandoffError,
             Whatsapp::WebhookTeardownService::WebhookTeardownError => e
        if inbox.restore_after_whatsapp_deletion_failure!(attempt_id: attempt_id)
          Rails.logger.warn("[INBOX DELETE] WhatsApp teardown failed before inbox data purge; recovery state recorded (#{e.class.name})")
          next :restored
        end

        raise
      end

      :success
    end

    return teardown.call if waba_id.blank?

    Whatsapp::WabaLock.new(waba_id).with_lock(&teardown)
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength

  def destroy_with_prepared_dependencies(object)
    if object.is_a?(Conversation)
      object.class.transaction do
        prepare_telephony_dependencies(object)
        object.destroy!
      end
      return
    end

    prepare_telephony_dependencies(object)

    # Pre-purge heavy associations for large objects to avoid
    # timeouts & race conditions due to destroy_async fan-out.
    purge_heavy_associations(object)
    object.destroy!
  end

  def build_post_deletion_context(object)
    case object
    when Inbox
      {
        channel_medium: object.channel.try(:medium),
        communication_thread_ids: communication_thread_ids_for_conversations(object.conversations.select(:id))
      }.compact
    when Conversation
      {
        communication_thread_ids: communication_thread_ids_for_conversations(object.id)
      }.compact
    else
      {}
    end
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

    channel = object.channel
    # Destroy WhatsApp channels before purging conversations. Their fail-closed
    # webhook teardown can abort, and valid customer data must remain intact on failure.
    case channel
    when Channel::Whatsapp then channel.destroy!
    when Channel::WhatsappWeb then channel.teardown_provider_instance!
    when Channel::TelegramPersonal then channel.teardown_runtime!
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

    delete_communication_thread_links(conversation_ids)
    nullify_records(Reminder.where(conversation_id: conversation_ids), conversation_id: nil)
    nullify_records(Reminder.where(target_conversation_id: conversation_ids), target_conversation_id: nil)
    nullify_records(Reminder.where(remindable_type: 'Conversation', remindable_id: conversation_ids), remindable_type: nil, remindable_id: nil)
    nullify_records(ConfirmationRequest.where(conversation_id: conversation_ids), conversation_id: nil)
    nullify_records(ConfirmationRequest.where(delivery_message_id: message_ids), delivery_message_id: nil)
    nullify_records(ConfirmationRequest.where(resolved_message_id: message_ids), resolved_message_id: nil)
    nullify_records(Crm::Deal.where(originating_conversation_id: conversation_ids), originating_conversation_id: nil)
    nullify_records(Crm::Task.where(originating_conversation_id: conversation_ids), originating_conversation_id: nil)
    nullify_records(Scheduling::Appointment.where(conversation_id: conversation_ids), conversation_id: nil)
    nullify_records(AssignmentQuotaUsage.where(conversation_id: conversation_ids), conversation_id: nil)
    delete_assignment_decision_logs(conversation_ids)
    delete_conversation_status_transitions(conversation_ids)
  end

  def communication_thread_ids_for_conversations(conversation_ids)
    ids = CommunicationThreadConversation
          .where(conversation_id: conversation_ids)
          .distinct
          .pluck(:communication_thread_id)

    ids.presence
  end

  def cleanup_empty_communication_threads(thread_ids)
    Array(thread_ids).compact.each_slice(BATCH_SIZE) do |ids|
      CommunicationThread.where(id: ids).find_each do |thread|
        next if thread.communication_thread_conversations.exists?

        nullify_records(
          Crm::Deal.where(originating_communication_thread_id: thread.id),
          originating_communication_thread_id: nil
        )
        thread.destroy!
      end
    end
  end

  def delete_communication_thread_links(conversation_ids)
    CommunicationThreadConversation
      .where(conversation_id: conversation_ids)
      .in_batches(of: BATCH_SIZE, &:delete_all)
  end

  def delete_assignment_decision_logs(conversation_ids)
    AssignmentDecisionLog
      .where(conversation_id: conversation_ids)
      .in_batches(of: BATCH_SIZE, &:delete_all)
  end

  def delete_conversation_status_transitions(conversation_ids)
    ConversationStatusTransition
      .where(conversation_id: conversation_ids)
      .in_batches(of: BATCH_SIZE, &:delete_all)
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

  def mark_pending_deletion(object, attempt_id: nil)
    return unless object.respond_to?(:mark_pending_deletion!)

    if object.is_a?(Inbox)
      object.mark_pending_deletion!(attempt_id: attempt_id)
    else
      object.mark_pending_deletion!
    end
  end

  def batch_destroy(relation)
    relation.find_in_batches(batch_size: BATCH_SIZE) do |batch|
      batch.each(&:destroy!)
    end
  end
end

DeleteObjectJob.prepend_mod_with('DeleteObjectJob')
