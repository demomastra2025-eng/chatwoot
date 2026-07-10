class Reminders::MessageMaterializer
  attr_reader :reminder

  def initialize(reminder:)
    @reminder = reminder
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
    )
    additional_attributes['captain_trace'] = captain_trace if captain_trace.present?
    additional_attributes['delivery_policy'] = delivery_policy.as_json if delivery_policy.present?

    message.update!(additional_attributes: additional_attributes)
    reminder.mark_delivery_materialized!(message.id) if reminder.persisted?
    message
  end

  private

  def message_params(content:)
    {
      content: content,
      template_params: reminder.template_params.presence,
      attachments: reminder.attachments.presence,
      content_attributes: {
        touch_id: reminder.id,
        touch_source: 'touch'
      }
    }.compact
  end
end
