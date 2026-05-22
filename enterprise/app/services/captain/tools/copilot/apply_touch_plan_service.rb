class Captain::Tools::Copilot::ApplyTouchPlanService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'apply_touch_plan'
  end

  description 'Apply an existing outbound touch plan to the current conversation, deal, task, or appointment'
  param :touch_plan_id, type: :number, desc: 'Touch plan ID to apply', required: false
  param :touch_plan_name, type: :string, desc: 'Touch plan name to apply when the ID is not known', required: false
  param :remindable_kind, type: :string, desc: 'Target entity: conversation, deal, task, appointment. Defaults to conversation', required: false

  def execute(touch_plan_id: nil, touch_plan_name: nil, remindable_kind: nil)
    touches = touch_operations.apply_touch_plan(
      touch_plan_id: touch_plan_id,
      touch_plan_name: touch_plan_name,
      remindable_kind: remindable_kind
    )

    formatted_payload(::Outbound::ToolPayloadBuilder.apply_touch_plan_payload(touches))
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
