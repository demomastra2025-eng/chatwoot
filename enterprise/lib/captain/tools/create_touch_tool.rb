class Captain::Tools::CreateTouchTool < Captain::Tools::BasePublicTool
  description(
    'Create a delayed outbound touch with free text, attachments, or an approved official WhatsApp channel template. ' \
    'Supports three scheduling modes: relative (relative_offset_minutes + optional relative_anchor), ' \
    'absolute (scheduled_at as ISO8601), and recurring (repeat_mode daily/weekly/monthly/weekdays with repeat_until_at). ' \
    'For a fixed wall-clock time on relative touches use relative_time_mode=fixed_time_of_day with relative_time_of_day HH:MM. ' \
    'For official WhatsApp outside the 24-hour window, use channel_template instead of free_text or AI-generated text.'
  )
  param :body, type: 'string', desc: 'Touch message body. Required for free_text touches; optional for channel_template touches', required: false
  param :content_kind, type: 'string',
                       desc: 'Touch content kind: free_text or channel_template. Defaults to channel_template when template_params are provided', required: false
  param :template_params, type: 'object',
                          desc: 'Approved channel template params for official WhatsApp touches, including name, language, namespace, and processed_params', required: false
  param :remindable_kind, type: 'string', desc: 'Target entity: conversation, deal, task, appointment. Defaults to conversation', required: false
  param :relative_anchor, type: 'string',
                          desc: 'Optional relative anchor: touch.created_at, conversation.created_at, conversation.last_incoming_message_at, conversation.last_activity_at, conversation.last_outgoing_message_at, conversation.waiting_since, deal.expected_close_on, task.due_at, appointment.starts_at, appointment.ends_at. Defaults to conversation.last_incoming_message_at for conversation touches, falling back to touch.created_at when no incoming customer message exists.', required: false
  param :relative_offset_minutes, type: 'number', desc: 'positive offset in minutes for relative scheduling', required: true
  param :repeat_mode, type: 'string',
                      desc: 'Recurrence mode: once (default), daily, weekly, monthly, weekdays. Requires repeat_until_at when not once.', required: false
  param :repeat_until_at, type: 'string', desc: 'ISO8601 stop time for recurring touches, e.g. 2026-08-01T18:00:00+03:00.', required: false
  param :scheduled_at, type: 'string',
                       desc: 'Absolute send time as ISO8601, e.g. 2026-07-10T15:00:00+03:00. Use instead of relative_offset_minutes for absolute scheduling.', required: false
  param :relative_time_mode, type: 'string',
                             desc: 'Relative time mode: inherit_anchor_time (default) or fixed_time_of_day. Use fixed_time_of_day with relative_time_of_day.', required: false
  param :relative_time_of_day, type: 'string', desc: 'Wall-clock time HH:MM (e.g. 10:00) when relative_time_mode is fixed_time_of_day.',
                               required: false
  param :timezone, type: 'string', desc: 'IANA timezone, for example Asia/Almaty', required: false
  param :target_inbox_id, type: 'number', desc: 'Optional explicit target inbox/channel ID', required: false
  param :auto_cancel_on_incoming, type: 'boolean',
                                  desc: 'Set true only when a customer reply in the same conversation should cancel this scheduled touch; set false when the touch must remain scheduled', required: false
  param :attachment_ids, type: 'array', desc: 'Optional ActiveStorage signed blob IDs to send when the touch executes', required: false
  param :artifact_ids, type: 'array',
                       desc: 'Optional opaque artifact IDs selected from custom HTTP tool artifact_candidates; materialized now for reliable scheduled delivery', required: false

  def perform(
    tool_context,
    body: nil,
    content_kind: nil,
    template_params: nil,
    remindable_kind: nil,
    relative_anchor: nil,
    relative_offset_minutes: nil,
    repeat_mode: nil,
    repeat_until_at: nil,
    scheduled_at: nil,
    relative_time_mode: nil,
    relative_time_of_day: nil,
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
      relative_anchor: relative_anchor,
      relative_offset_minutes: relative_offset_minutes,
      repeat_mode: repeat_mode,
      repeat_until_at: repeat_until_at,
      scheduled_at: scheduled_at,
      relative_time_mode: relative_time_mode,
      relative_time_of_day: relative_time_of_day,
      timezone: timezone,
      target_inbox_id: target_inbox_id,
      auto_cancel_on_incoming: auto_cancel_on_incoming,
      attachment_ids: attachment_ids,
      artifact_ids: artifact_ids
    )

    tool_success(data: ::Outbound::ToolPayloadBuilder.touch_payload(action: 'create_touch', touch: touch))
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
