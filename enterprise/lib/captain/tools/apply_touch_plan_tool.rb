class Captain::Tools::ApplyTouchPlanTool < Captain::Tools::BasePublicTool
  description 'Apply an existing outbound touch plan to the current conversation, deal, task, or appointment'
  param :touch_plan_id, type: 'number', desc: 'Touch plan ID to apply', required: false
  param :touch_plan_name, type: 'string', desc: 'Touch plan name to apply when the ID is not known', required: false
  param :remindable_kind, type: 'string', desc: 'Target entity: conversation, deal, task, appointment. Defaults to conversation', required: false

  def perform(tool_context, touch_plan_id: nil, touch_plan_name: nil, remindable_kind: nil)
    touches = operations(tool_context.state).apply_touch_plan(
      touch_plan_id: touch_plan_id,
      touch_plan_name: touch_plan_name,
      remindable_kind: remindable_kind
    )

    JSON.pretty_generate(
      action: 'apply_touch_plan',
      touches: touches.map { |touch| ::Outbound::PayloadBuilder.touch_payload(touch) },
      meta: { count: touches.size }
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
