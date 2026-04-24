class Captain::Tools::Copilot::CreateTouchService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'create_touch'
  end

  description 'Create a scheduled outbound touch for the current conversation or linked CRM context'
  param :body, type: :string, desc: 'Touch message body', required: true
  param :remindable_kind, type: :string, desc: 'Target entity: conversation, deal, task, appointment. Defaults to conversation', required: false
  param :scheduled_at, type: :string, desc: 'Absolute execution datetime', required: false
  param :relative_anchor, type: :string,
                          desc: 'Optional relative anchor: touch.created_at, conversation.created_at, deal.expected_close_on, task.due_at, appointment.starts_at, appointment.ends_at', required: false
  param :relative_offset_minutes, type: :number, desc: 'Offset in minutes for relative scheduling', required: false
  param :timezone, type: :string, desc: 'IANA timezone, for example Asia/Almaty', required: false
  param :target_inbox_id, type: :number, desc: 'Optional explicit target inbox/channel ID', required: false
  param :auto_cancel_on_incoming, type: :boolean, desc: 'Cancel the touch if the customer replies in the same target', required: false

  def execute(
    body:,
    remindable_kind: nil,
    scheduled_at: nil,
    relative_anchor: nil,
    relative_offset_minutes: nil,
    timezone: nil,
    target_inbox_id: nil,
    auto_cancel_on_incoming: nil
  )
    touch = touch_operations.create_touch(
      body: body,
      remindable_kind: remindable_kind,
      scheduled_at: scheduled_at,
      relative_anchor: relative_anchor,
      relative_offset_minutes: relative_offset_minutes,
      timezone: timezone,
      target_inbox_id: target_inbox_id,
      auto_cancel_on_incoming: auto_cancel_on_incoming
    )

    formatted_payload(
      action: 'create_touch',
      touch: ::Outbound::PayloadBuilder.touch_payload(touch)
    )
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    user_has_permission('outbound_manage')
  end

  private

  def touch_operations
    Captain::Tools::Operations::TouchOperations.new(
      assistant: assistant,
      conversation: current_conversation,
      actor: @user
    )
  end
end
