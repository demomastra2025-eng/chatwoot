class Captain::Tools::Copilot::CancelTouchesService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'cancel_touches'
  end

  description 'Cancel draft and pending scheduled outbound touches for the current entity, optionally filtered by touch plan'
  param :remindable_kind, type: :string, desc: 'Target entity: conversation, deal, task, appointment. Defaults to conversation', required: false
  param :touch_plan_id, type: :number, desc: 'Optional touch plan ID used to cancel only touches created from that plan', required: false
  param :touch_plan_name, type: :string, desc: 'Optional touch plan name used when the ID is not known', required: false
  param :reason, type: :string, desc: 'Optional cancellation reason', required: false

  def execute(remindable_kind: nil, touch_plan_id: nil, touch_plan_name: nil, reason: nil)
    result = touch_operations.cancel_touches(
      remindable_kind: remindable_kind,
      touch_plan_id: touch_plan_id,
      touch_plan_name: touch_plan_name,
      reason: reason
    )

    formatted_payload(::Outbound::ToolPayloadBuilder.cancel_touches_payload(result: result, reason: reason))
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
