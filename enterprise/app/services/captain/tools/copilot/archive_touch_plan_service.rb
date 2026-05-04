class Captain::Tools::Copilot::ArchiveTouchPlanService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'archive_touch_plan'
  end

  description 'Archive an outbound touch plan so it is no longer used for new scheduled touches'
  param :touch_plan_id, type: :number, desc: 'Touch plan ID to archive', required: false
  param :touch_plan_name, type: :string, desc: 'Touch plan name to archive when the ID is not known', required: false

  def execute(touch_plan_id: nil, touch_plan_name: nil)
    touch_plan = touch_operations.archive_touch_plan(touch_plan_id: touch_plan_id, touch_plan_name: touch_plan_name)

    formatted_payload(
      action: 'archive_touch_plan',
      touch_plan: ::Outbound::PayloadBuilder.touch_plan_payload(touch_plan)
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
