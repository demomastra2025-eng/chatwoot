class Captain::Tools::ArchiveTouchPlanTool < Captain::Tools::BasePublicTool
  description 'Archive an outbound touch plan so it is no longer used for new scheduled touches'
  param :touch_plan_id, type: 'number', desc: 'Touch plan ID to archive', required: false
  param :touch_plan_name, type: 'string', desc: 'Touch plan name to archive when the ID is not known', required: false

  def perform(tool_context, touch_plan_id: nil, touch_plan_name: nil)
    touch_plan = operations(tool_context.state).archive_touch_plan(
      touch_plan_id: touch_plan_id,
      touch_plan_name: touch_plan_name
    )

    tool_success(data: ::Outbound::ToolPayloadBuilder.touch_plan_payload(action: 'archive_touch_plan', touch_plan: touch_plan))
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
