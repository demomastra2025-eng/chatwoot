class Captain::Tools::CreateTouchTool < Captain::Tools::BasePublicTool
  description 'Create a scheduled outbound touch with free text, attachments, or an approved WhatsApp/Twilio channel template'
  param :body, type: 'string', desc: 'Touch message body. Required for free_text touches; optional for channel_template touches', required: false
  param :content_kind, type: 'string',
                       desc: 'Touch content kind: free_text or channel_template. Defaults to channel_template when template_params are provided', required: false
  param :template_params, type: 'object',
                          desc: 'Approved channel template params for WhatsApp/Twilio WhatsApp touches, including name, language, namespace, and processed_params', required: false
  param :remindable_kind, type: 'string', desc: 'Target entity: conversation, deal, task, appointment. Defaults to conversation', required: false
  param :scheduled_at, type: 'string', desc: 'Absolute execution datetime', required: false
  param :relative_anchor, type: 'string',
                          desc: 'Optional relative anchor: touch.created_at, conversation.created_at, deal.expected_close_on, task.due_at, appointment.starts_at, appointment.ends_at', required: false
  param :relative_offset_minutes, type: 'number', desc: 'Offset in minutes for relative scheduling', required: false
  param :timezone, type: 'string', desc: 'IANA timezone, for example Asia/Almaty', required: false
  param :target_inbox_id, type: 'number', desc: 'Optional explicit target inbox/channel ID', required: false
  param :auto_cancel_on_incoming, type: 'boolean', desc: 'Cancel the touch if the customer replies in the same target', required: false
  param :attachment_ids, type: 'array', desc: 'Optional ActiveStorage signed blob IDs to send when the touch executes', required: false
  param :artifact_ids, type: 'array',
                       desc: 'Optional opaque artifact IDs selected from custom HTTP tool artifact_candidates; materialized now for reliable scheduled delivery', required: false

  def perform(
    tool_context,
    body: nil,
    content_kind: nil,
    template_params: nil,
    remindable_kind: nil,
    scheduled_at: nil,
    relative_anchor: nil,
    relative_offset_minutes: nil,
    timezone: nil,
    target_inbox_id: nil,
    auto_cancel_on_incoming: nil,
    attachment_ids: [],
    artifact_ids: []
  )
    touch = operations(tool_context.state).create_touch(
      body: body,
      content_kind: content_kind,
      template_params: template_params,
      remindable_kind: remindable_kind,
      scheduled_at: scheduled_at,
      relative_anchor: relative_anchor,
      relative_offset_minutes: relative_offset_minutes,
      timezone: timezone,
      target_inbox_id: target_inbox_id,
      auto_cancel_on_incoming: auto_cancel_on_incoming,
      attachment_ids: attachment_ids,
      artifact_ids: artifact_ids
    )

    JSON.pretty_generate(
      action: 'create_touch',
      touch: ::Outbound::PayloadBuilder.touch_payload(touch)
    )
  rescue StandardError => e
    tool_failure(e)
  end

  private

  def operations(state)
    Captain::Tools::Operations::TouchOperations.new(
      assistant: assistant,
      conversation: current_conversation(state)
    )
  end
end
