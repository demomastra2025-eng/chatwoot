class Reminders::MessageMaterializer
  attr_reader :reminder, :template_params, :confirmation_request

  def initialize(reminder:, template_params: reminder.template_params.presence, confirmation_request: nil)
    @reminder = reminder
    @template_params = template_params
    @confirmation_request = confirmation_request
  end

  def perform(conversation:, sender:, content:, captain_trace: nil, delivery_policy: nil)
    message = Messages::MessageBuilder.new(
      sender,
      conversation,
      ActionController::Parameters.new(message_params(content: content)),
      skip_send_reply: true
    ).perform

    additional_attributes = (message.additional_attributes || {}).merge(
      'touch_id' => reminder.id,
      'touch_source' => 'touch'
    ).merge(automation_provenance)
    additional_attributes['captain_trace'] = captain_trace if captain_trace.present?
    additional_attributes['delivery_policy'] = delivery_policy.as_json if delivery_policy.present?

    message.update!(additional_attributes: additional_attributes)
    confirmation_request&.update!(delivery_message: message)
    reminder.mark_delivery_materialized!(message.id) if reminder.persisted?
    message
  end

  private

  def message_params(content:)
    {
      content: content,
      template_params: template_params,
      attachments: reminder.attachments.presence,
      content_attributes: {
        touch_id: reminder.id,
        touch_source: 'touch'
      }.merge(automation_content_attributes).merge(confirmation_content_attributes)
    }.compact
  end

  def automation_provenance
    automation_rule_id = reminder.metadata.to_h[Reminder::POST_DELIVERY_AUTOMATION_RULE_ID_KEY]
    return {} unless reminder.metadata.to_h[Reminder::POST_DELIVERY_AUDIT_SOURCE_KEY] == 'automation'
    return {} if automation_rule_id.blank?

    {
      'automation_rule_id' => automation_rule_id,
      'touch_origin' => 'automation'
    }
  end

  def automation_content_attributes
    automation_rule_id = automation_provenance['automation_rule_id']
    automation_rule_id.present? ? { automation_rule_id: automation_rule_id } : {}
  end

  def confirmation_content_attributes
    return {} if confirmation_request.blank?

    {
      confirmation_request_id: confirmation_request.id,
      confirmation_token: confirmation_request.token
    }
  end
end
