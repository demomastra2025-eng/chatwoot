class Reminders::ExecuteService
  PROVIDER_GUARD_BLOCKED = Object.new.freeze
  NOTIFICATION_ROUTE_CHANGED = Object.new.freeze
  ROUTE_CHANGE_FAILED = 'Touch could not be moved to the current notification contact'.freeze
  TRANSIENT_DATABASE_ERRORS = [
    ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout, ActiveRecord::SerializationFailure, ActiveRecord::QueryCanceled
  ].freeze
  TRANSIENT_FINISH_RETRY_DELAY = 5.seconds

  attr_reader :reminder

  def initialize(reminder:, processing_claim: reminder.processing_claim_token)
    @reminder = reminder
    @processing_claim = processing_claim
  end

  def perform
    reload_reminder
    return complete_dispatched_execution if dispatched_before_completion?
    return reminder if execution_ineligible?
    return reminder if Reminders::MissedAutomationTouchPolicy.new(reminder: reminder).cancel_if_missed!
    return reminder if appointment_provider_blocked?(:materialization)
    return finish_execution if reminder.delivery_materialized?

    execute_action
  rescue *TRANSIENT_DATABASE_ERRORS => e
    release_claim_for_retry!(e)
    reminder
  rescue StandardError => e
    fail_reminder!(e.message)
    raise
  end

  private

  def execution_ineligible?
    return true if reminder.cancelled? || reminder.completed? || reminder.failed?

    reminder.persisted? && (!reminder.processing? || !current_execution_claim?)
  end

  def execute_action
    ensure_routable_patient_route!
    realign_notification_route!
    case reminder.action_type
    when 'send_message'
      execute_send_message
    when 'ai_agent_wakeup'
      execute_ai_agent_wakeup
    else
      raise ArgumentError, "Unsupported touch action: #{reminder.action_type}"
    end
  end

  # The route is evaluated at send time: a separate patient's own primary number wins over the shared owner's route,
  # so a touch scheduled or claimed before that number appeared (or was removed) is re-pointed under its claim first.
  def realign_notification_route!
    return reminder.align_notification_contact unless reminder.persisted?
    return unless notification_contact_changed?

    reminder.with_lock do
      reminder.reload
      reminder.align_notification_contact.save! if reminder.processing? && current_execution_claim?
    end
    @execution_updated_at = reminder.updated_at
  rescue ActiveRecord::RecordInvalid => e
    # The re-pointed route was rolled back with the lock, so the failure names the route it was meant for.
    raise Reminders::UndeliverableTargetError,
          "#{ROUTE_CHANGE_FAILED} (contact ##{e.record.target_contact_id}): #{e.record.errors.full_messages.to_sentence}"
  end

  # H2c: an appointment without a booking chat whose доп. номер has no verified phone chat is never sent over any
  # other chat of the holder or share owner; the touch fails visibly with the route-required reason (no re-send).
  def ensure_routable_patient_route!
    return unless reminder.remindable.is_a?(Scheduling::Appointment) && reminder.notification_route.unroutable?

    raise Reminders::UndeliverableTargetError, Reminders::TargetRouteResolver::ROUTE_REASSIGNMENT_MESSAGE
  end

  def notification_contact_changed?
    return false unless reminder.remindable.is_a?(Scheduling::Appointment)

    contact = reminder.notification_route.contact
    contact.present? && reminder.target_contact_id != contact.id
  end

  def appointment_provider_blocked?(phase)
    Reminders::AppointmentProviderGuard.new(reminder: reminder, phase: phase).perform ==
      Reminders::AppointmentProviderGuard::STOP
  end

  def execute_send_message
    conversation = Reminders::ConversationResolver.new(reminder: reminder).perform
    return reminder if execution_blocked?(conversation)

    payload = send_message_payload(conversation)
    delivery_policy = send_message_delivery_policy(conversation, template_params: payload[:template_params])
    message = finalize_send_message(conversation, payload, delivery_policy)
    return reminder if message.equal?(PROVIDER_GUARD_BLOCKED) || message.equal?(NOTIFICATION_ROUTE_CHANGED)

    finish_execution(message)
  end

  def send_message_delivery_policy(conversation, template_params:)
    ensure_delivery_allowed!(
      conversation,
      content_kind: reminder.content_kind,
      template_params: template_params,
      attachments: reminder.attachments
    )
  end

  def send_message_payload(conversation)
    generated_payload = reminder.agent? ? generate_captain_message(conversation, mode: :touch) : {}
    sender = generated_payload[:assistant].presence || reminder.message_sender
    confirmation_request = Reminders::ConfirmationRequestService.new(reminder: reminder, conversation: conversation).perform
    template_params = rendered_template_params(conversation, sender, confirmation_request)

    {
      sender: sender,
      content: generated_payload[:content].presence || reminder.renderable_body(conversation: conversation, sender: sender),
      captain_trace: generated_payload[:captain_trace],
      template_params: template_params,
      confirmation_request: confirmation_request
    }
  end

  def finalize_send_message(conversation, payload, delivery_policy)
    with_execution_lock do
      next requeue_moved_conversation!(conversation) if conversation_owner_changed?(conversation)
      next requeue_changed_notification_route! if notification_route_changed?(conversation)

      message = Reminders::MessageMaterializer.new(
        reminder: reminder,
        template_params: payload[:template_params],
        confirmation_request: payload[:confirmation_request]
      ).perform(
        conversation: conversation,
        sender: payload[:sender],
        content: payload[:content],
        captain_trace: payload[:captain_trace],
        delivery_policy: delivery_policy
      )
      update_resolved_targets!(conversation)
      @execution_updated_at = reminder.updated_at
      message
    end
  end

  # Re-checked under the appointment and touch locks: a primary number that appeared or disappeared after the
  # conversation was resolved re-queues the touch for its current route instead of sending on the previous one.
  def notification_route_changed?(conversation)
    return false unless reminder.persisted? && reminder.remindable.is_a?(Scheduling::Appointment)

    route = reminder.notification_route
    return true if route.unroutable?

    route.contact.present? && conversation.contact_id != route.contact.id
  end

  def requeue_changed_notification_route!
    reminder.assign_attributes(status: :pending, processing_started_at: nil)
    prepare_requeued_wakeup_route! if reminder.ai_agent_wakeup?
    reminder.save!
    NOTIFICATION_ROUTE_CHANGED
  end

  # A number transfer (M6) can move the resolved conversation to another contact after it was resolved. Under the
  # appointment and touch locks the conversation row is locked the way the transfer locks it (FOR NO KEY UPDATE, so the
  # two serialize; the transfer locks touches before conversations, like this execution) and its owner re-read: a chat
  # that changed owner since it was resolved is never used for this delivery.
  def conversation_owner_changed?(conversation)
    return false unless reminder.persisted? && conversation&.persisted?

    Conversation.where(id: conversation.id).lock('FOR NO KEY UPDATE').pick(:contact_id) != conversation.contact_id
  end

  # The moved chat is dropped from the touch targets and the touch is re-queued for its current route.
  def requeue_moved_conversation!(conversation)
    reminder.target_conversation = nil if reminder.target_conversation_id == conversation.id
    reminder.target_contact_inbox = nil if reminder.target_contact_inbox_id == conversation.contact_inbox_id
    requeue_changed_notification_route!
  end

  # A wakeup is claimable only with a conversation: the re-queued one gets the conversation of its current route (found
  # or created like a message touch). When that route is not deliverable the touch stays a visible draft; it never runs
  # on the previous route.
  def prepare_requeued_wakeup_route!
    reminder.align_notification_contact
    return if reminder.target_conversation.present? || reminder.conversation.present?

    conversation = Reminders::ConversationResolver.new(reminder: reminder).perform
    reminder.assign_attributes(target_conversation: conversation, target_contact_inbox: conversation.contact_inbox)
  rescue Reminders::UndeliverableTargetError
    nil
  end

  def update_resolved_targets!(conversation)
    updates = {}
    updates[:target_conversation] = conversation if reminder.target_conversation_id != conversation.id
    if reminder.post_delivery_action.present? && reminder.remindable.is_a?(Conversation) && reminder.remindable_id != conversation.id
      updates[:conversation] = conversation
      updates[:remindable] = conversation
    end
    updates[:target_contact_inbox] = conversation.contact_inbox if reminder.target_contact_inbox_id != conversation.contact_inbox_id
    reminder.update!(updates) if updates.present?
  end

  def execute_ai_agent_wakeup
    conversation = wakeup_conversation
    raise ArgumentError, 'AI wakeup touches require a conversation target' if conversation.blank?
    return reminder if execution_blocked?(conversation)

    delivery_policy = ensure_delivery_allowed!(conversation, content_kind: 'free_text', template_params: {}, attachments: [])
    generated_payload = generate_captain_message(conversation, mode: :wakeup)
    message = finalize_ai_agent_wakeup(conversation, generated_payload, delivery_policy)
    return reminder if message.equal?(PROVIDER_GUARD_BLOCKED) || message.equal?(NOTIFICATION_ROUTE_CHANGED)

    finish_execution(message)
  end

  # A wakeup of a separate patient's appointment runs in the conversation of its current route contact (own number,
  # holder, booking chat), found or created in the target inbox exactly like a message touch; another contact's
  # conversation is never used for it.
  def wakeup_conversation
    conversation = reminder.target_conversation || reminder.conversation
    return conversation unless Reminders::PatientSubjectGuard.no_steal_route?(reminder)
    return conversation if conversation.present? && conversation.contact_id == reminder.target_contact_id

    Reminders::ConversationResolver.new(reminder: reminder).perform
  end

  # Re-checked under the appointment and touch locks like a message touch: a route that changed during generation
  # re-queues the wakeup for its current route instead of running it in the previous conversation.
  def finalize_ai_agent_wakeup(conversation, generated_payload, delivery_policy)
    with_execution_lock do
      next requeue_moved_conversation!(conversation) if conversation_owner_changed?(conversation)
      next requeue_changed_notification_route! if notification_route_changed?(conversation)

      Reminders::WakeupConversationPreparer.new(conversation: conversation).perform
      message = Reminders::MessageMaterializer.new(reminder: reminder).perform(
        conversation: conversation,
        sender: generated_payload[:assistant],
        content: generated_payload[:content],
        captain_trace: generated_payload[:captain_trace],
        delivery_policy: delivery_policy
      )
      update_wakeup_targets!(conversation)
      @execution_updated_at = reminder.updated_at
      message
    end
  end

  def update_wakeup_targets!(conversation)
    updates = {}
    updates[:target_conversation] = conversation if reminder.target_conversation_id != conversation.id
    if Reminders::PatientSubjectGuard.no_steal_route?(reminder) && reminder.target_contact_inbox_id != conversation.contact_inbox_id
      updates[:target_contact_inbox] = conversation.contact_inbox
    end
    reminder.update!(updates) if updates.present?
  end

  def finish_execution(message = nil)
    Reminders::ExecutionFinisher.new(
      reminder: reminder,
      processing_claim: @processing_claim
    ).perform(message)
  end

  def execution_blocked?(conversation)
    return false unless reminder.persisted?

    campaign_policy = Reminders::CampaignConflictPolicy.new(
      reminder: reminder,
      conversation: conversation,
      processing_claim: @processing_claim
    )
    return true if campaign_policy.cancel_if_conflict!

    Reminders::DeliveryWindowPolicy.apply!(
      reminder: reminder,
      conversation: conversation,
      processing_claim: @processing_claim
    ).blocked?
  end

  def with_execution_lock(&)
    guarded_execution = lambda do
      next PROVIDER_GUARD_BLOCKED if appointment_provider_blocked?(:materialization)

      yield
    end
    return guarded_execution.call unless reminder.persisted?

    Reminders::ExecutionLockService.new(
      reminder: reminder,
      processing_claim: @processing_claim,
      execution_updated_at: @execution_updated_at
    ).perform(&guarded_execution)
  end

  def reload_reminder
    reminder.reload if reminder.persisted?
    @execution_updated_at = reminder.updated_at
  end

  def current_execution_claim?
    reminder.processing_claim_token == @processing_claim
  end

  def stale_execution?
    @execution_updated_at.present? && reminder.updated_at != @execution_updated_at
  end

  def reset_stale_execution!
    reminder.update!(status: :pending, processing_started_at: nil)
  end

  # A deadlock, lock timeout, serialization failure or cancelled query is not the touch's fault.
  #   - Nothing committed yet (the failed transaction rolled back, no message exists): the claim is released
  #     (processing -> pending, like a stale execution) and the scheduler re-claims the due touch.
  #   - The message was already materialized (committed with its delivery job enqueued), e.g. the completion waited for
  #     the touch row behind a number transfer: the touch keeps its claim and only the finishing step is retried with it.
  #     Releasing it would let the scheduler's next claim drop the materialization marker and send the touch again (M3:
  #     no duplicates), and the queued delivery job, bound to this claim, would no longer match.
  # The in-memory touch may carry changes of the rolled-back attempt; they are discarded before locking.
  def release_claim_for_retry!(error)
    ChatwootExceptionTracker.new(error, account: reminder.account).capture_exception
    return unless reminder.persisted?

    reminder.reload
    materialized_finish_pending? ? retry_materialized_finish! : release_unmaterialized_claim!
  rescue ActiveRecord::ActiveRecordError => e
    Rails.logger.warn({ event: 'reminder_transient_retry_release_failed', reminder_id: reminder.id, error: e.class.name }.to_json)
  end

  def release_unmaterialized_claim!
    reminder.with_lock do
      reminder.reload
      next unless reminder.processing? && current_execution_claim?
      next if reminder.delivery_materialized?

      reset_stale_execution!
    end
  end

  # Still ours to finish: materialized under this claim, or already dispatched by its delivery job, which consumed the
  # claim (sc8rv2 E2T). Either way the finishing step is retried with this claim and never re-sends.
  def materialized_finish_pending?
    reminder.delivery_materialized? && (current_execution_claim? || dispatched_before_completion?)
  end

  def dispatched_before_completion?
    reminder.persisted? && @processing_claim.present? && Reminders::ExecutionFinisher.dispatched_before_completion?(reminder)
  end

  def complete_dispatched_execution
    Reminders::ExecutionFinisher.new(reminder: reminder, processing_claim: @processing_claim).complete_dispatched
  end

  def retry_materialized_finish!
    Reminders::ExecuteReminderJob.set(wait: TRANSIENT_FINISH_RETRY_DELAY).perform_later(reminder.id, @processing_claim)
  end

  def fail_reminder!(message)
    return reminder.fail!(message) unless reminder.persisted?

    reminder.reload if reminder.has_changes_to_save?
    reminder.with_lock do
      reminder.reload
      next unless reminder.processing?
      next unless current_execution_claim?

      stale_execution? ? reset_stale_execution! : reminder.fail!(message)
    end
  end

  def generate_captain_message(conversation, mode:)
    Reminders::CaptainGeneratedMessageService.new(
      reminder: reminder,
      conversation: conversation,
      mode: mode
    ).perform
  end

  def rendered_template_params(conversation, sender, confirmation_request)
    return reminder.template_params unless reminder.channel_template?

    params = reminder.renderable_template_params(conversation: conversation, sender: sender)
    if confirmation_request.present?
      params = Reminders::ConfirmationTemplateParamsService.new(
        reminder: reminder,
        confirmation_request: confirmation_request
      ).perform(params)
    end
    Campaigns::TemplateParamsValidator.validate!(inbox: conversation.inbox, template_params: params)
    params
  end

  def ensure_delivery_allowed!(conversation, content_kind:, template_params:, attachments:)
    ::Outbound::DeliveryPolicy.ensure!(
      conversation: conversation,
      content_kind: content_kind,
      template_params: template_params,
      attachments: attachments,
      scheduled_at: Time.current
    )
  end
end
