class AutomationRules::ActionService < ActionService
  def initialize(rule, account, conversation, trigger_message: nil, execution_key: nil)
    super(conversation)
    @rule = rule
    @account = account
    @trigger_message = trigger_message
    @execution_key = execution_key
    Current.executed_by = rule
  end

  def perform
    action_runner.perform do |action, index|
      @conversation.reload
      begin
        @current_action_id = action[:action_id]
        @current_action_key = @current_action_id.presence || "legacy-index:#{index}"
        send(action[:action_name], action[:action_params])
      ensure
        @current_action_id = nil
        @current_action_key = nil
      end
    end
  ensure
    Current.reset
  end

  private

  def action_runner
    @action_runner ||= AutomationRules::ActionRunner.new(
      rule: @rule,
      account: @account,
      execution_key: @execution_key
    )
  end

  def send_attachment(blob_ids)
    return if conversation_a_tweet?

    return unless @rule.files.attached?

    blobs = ActiveStorage::Blob.where(id: blob_ids)

    return if blobs.blank?

    params = { content: nil, private: false, attachments: blobs }
    Messages::MessageBuilder.new(nil, @conversation, params).perform
  end

  def send_webhook_event(webhook_url)
    payload = @conversation.webhook_data.merge(event: "automation_event.#{@rule.event_name}")
    WebhookJob.perform_later(webhook_url[0], payload)
  end

  def send_message(message)
    return if conversation_a_tweet?

    if rich_message_params?(message)
      return touch_action_service.send_message(
        message,
        action_id: @current_action_id,
        action_key: @current_action_key
      )
    end

    content = message.is_a?(Hash) ? message[:message] || message['message'] : message[0]
    params = { content: content, private: false, content_attributes: { automation_rule_id: @rule.id } }
    Messages::MessageBuilder.new(nil, @conversation, params).perform
  end

  def rich_message_params?(message)
    return false unless message.is_a?(Hash) || message.is_a?(ActionController::Parameters)

    message.keys.map(&:to_s).intersect?(%w[body content_kind text_mode template_id])
  end

  def apply_touch_plan(action_params)
    touch_action_service.apply_touch_plan(action_params, action_key: @current_action_key)
  end

  def create_touch(action_params)
    touch_action_service.create_touch(
      action_params,
      action_id: @current_action_id,
      action_key: @current_action_key
    )
  end

  def cancel_touches(action_params)
    touch_action_service.cancel_touches(action_params)
  end

  def add_private_note(message)
    return if conversation_a_tweet?

    params = { content: message[0], private: true, content_attributes: { automation_rule_id: @rule.id } }
    Messages::MessageBuilder.new(nil, @conversation.reload, params).perform
  end

  def send_email_to_team(params)
    teams = Team.where(id: params[0][:team_ids])

    teams.each do |team|
      break unless @account.within_email_rate_limit?

      TeamNotifications::AutomationNotificationMailer.conversation_creation(@conversation, team, params[0][:message])&.deliver_now
      @account.increment_email_sent_count
    end
  end

  def touch_action_service
    @touch_action_service ||= AutomationRules::TouchActionService.new(
      rule: @rule,
      account: @account,
      record: @conversation,
      entity_kind: 'conversation',
      trigger_message: @trigger_message,
      execution_key: @execution_key
    )
  end
end
