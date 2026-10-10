class Reminders::MessageMaterializer
  attr_reader :reminder, :template_params, :confirmation_request

  def initialize(reminder:, template_params: reminder.template_params.presence, confirmation_request: nil, additional_attributes: {})
    @reminder = reminder
    @template_params = template_params
    @confirmation_request = confirmation_request
    @additional_attributes = additional_attributes.to_h
  end

  def perform(conversation:, sender:, content:, captain_trace: nil, delivery_policy: nil)
    policy = Outbound::PlaygroundDeliveryPolicy.policy_for(conversation: conversation, reminder: reminder)
    Outbound::PlaygroundDeliveryPolicy.ensure!(conversation: conversation, policy: policy)
    Message.transaction do
      message = materialize_message(conversation: conversation, sender: sender, content: content)
      verify_attachment_materialization!(message)

      attributes = materialized_message_attributes(message, captain_trace: captain_trace, delivery_policy: delivery_policy, playground_policy: policy)
      message.update!(additional_attributes: attributes)
      confirmation_request&.update!(delivery_message: message)
      reminder.mark_delivery_materialized!(message.id) if reminder.persisted?
      message
    end
  end

  private

  def materialize_message(conversation:, sender:, content:)
    Messages::MessageBuilder.new(
      sender,
      conversation,
      ActionController::Parameters.new(message_params(content: content)),
      skip_send_reply: true
    ).perform
  end

  def materialized_message_attributes(message, captain_trace:, delivery_policy:, playground_policy:)
    attributes = (message.additional_attributes || {}).merge(
      'touch_id' => reminder.id,
      'touch_source' => 'touch'
    ).merge(automation_provenance)
    attributes['captain_trace'] = captain_trace if captain_trace.present?
    attributes['delivery_policy'] = delivery_policy.as_json if delivery_policy.present?
    attributes[Outbound::PlaygroundDeliveryPolicy::ATTRIBUTE_KEY] = playground_policy.deep_dup unless playground_policy.nil?
    attributes.merge(@additional_attributes)
  end

  def message_params(content:)
    {
      content: content,
      template_params: template_params,
      attachments: materialized_attachments,
      content_attributes: {
        touch_id: reminder.id,
        touch_source: 'touch'
      }.merge(automation_content_attributes).merge(confirmation_content_attributes)
    }.compact
  end

  def materialized_attachments
    retained_files = reminder.files.attachments.includes(:blob).to_a
    return retained_files.map(&:blob) if retained_files.present?

    reminder.attachments.presence
  end

  def verify_attachment_materialization!(message)
    expected_count = reminder.files.count.presence || Array(reminder.attachments).size
    return if expected_count.zero? || message.attachments.count == expected_count

    message.errors.add(:attachments, 'could not be materialized for the conversation timeline')
    raise ActiveRecord::RecordInvalid, message
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
