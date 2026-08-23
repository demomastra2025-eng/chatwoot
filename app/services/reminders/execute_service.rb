class Reminders::ExecuteService
  attr_reader :reminder

  def initialize(reminder:, processing_claim: reminder.processing_claim_token)
    @reminder = reminder
    @processing_claim = processing_claim
  end

  def perform
    reload_reminder
    return reminder if execution_ineligible?
    return reminder if Reminders::MissedAutomationTouchPolicy.new(reminder: reminder).cancel_if_missed!
    return finish_execution if reminder.delivery_materialized?

    execute_action
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
    case reminder.action_type
    when 'send_message'
      execute_send_message
    when 'ai_agent_wakeup'
      execute_ai_agent_wakeup
    else
      raise ArgumentError, "Unsupported touch action: #{reminder.action_type}"
    end
  end

  def execute_send_message
    conversation = Reminders::ConversationResolver.new(reminder: reminder).perform
    return reminder if execution_blocked?(conversation)

    payload = send_message_payload(conversation)
    delivery_policy = send_message_delivery_policy(conversation, template_params: payload[:template_params])
    message = finalize_send_message(conversation, payload, delivery_policy)

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

  def update_resolved_targets!(conversation)
    updates = {}
    updates[:target_conversation] = conversation if reminder.target_conversation_id != conversation.id
    updates[:target_contact_inbox] = conversation.contact_inbox if reminder.target_contact_inbox_id != conversation.contact_inbox_id
    reminder.update!(updates) if updates.present?
  end

  def execute_ai_agent_wakeup
    conversation = reminder.target_conversation || reminder.conversation
    raise ArgumentError, 'AI wakeup touches require a conversation target' if conversation.blank?
    return reminder if execution_blocked?(conversation)

    delivery_policy = ensure_delivery_allowed!(conversation, content_kind: 'free_text', template_params: {}, attachments: [])
    generated_payload = generate_captain_message(conversation, mode: :wakeup)
    message = finalize_ai_agent_wakeup(conversation, generated_payload, delivery_policy)

    finish_execution(message)
  end

  def finalize_ai_agent_wakeup(conversation, generated_payload, delivery_policy)
    with_execution_lock do
      Reminders::WakeupConversationPreparer.new(conversation: conversation).perform
      message = Reminders::MessageMaterializer.new(reminder: reminder).perform(
        conversation: conversation,
        sender: generated_payload[:assistant],
        content: generated_payload[:content],
        captain_trace: generated_payload[:captain_trace],
        delivery_policy: delivery_policy
      )
      reminder.update!(target_conversation: conversation) if reminder.target_conversation_id != conversation.id
      @execution_updated_at = reminder.updated_at
      message
    end
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
    return yield unless reminder.persisted?

    Reminders::ExecutionLockService.new(
      reminder: reminder,
      processing_claim: @processing_claim,
      execution_updated_at: @execution_updated_at
    ).perform(&)
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

  def fail_reminder!(message)
    return reminder.fail!(message) unless reminder.persisted?

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
