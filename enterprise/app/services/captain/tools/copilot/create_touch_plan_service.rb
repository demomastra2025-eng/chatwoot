class Captain::Tools::Copilot::CreateTouchPlanService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'create_touch_plan'
  end

  description 'Create a reusable AI staff follow-up scenario with one or more scheduled touch definitions'
  param :name, type: :string, desc: 'Follow-up scenario name', required: true
  param :description, type: :string, desc: 'Optional follow-up scenario description', required: false
  param :entity_kinds, type: :array, desc: 'Supported entity kinds: conversation, deal, task, appointment. Defaults to conversation', required: false
  param :touches, type: :array,
                  desc: 'Array of touch definitions using touch fields such as body, content_kind, timing_mode, scheduled_at, relative_anchor, relative_offset_seconds, timezone, target_inbox_id, template_params, metadata',
                  required: true

  def execute(name:, touches:, description: nil, entity_kinds: nil)
    touch_plan = touch_operations.create_touch_plan(
      name: name,
      description: description,
      entity_kinds: entity_kinds,
      touches: touches
    )

    formatted_payload(::Outbound::ToolPayloadBuilder.touch_plan_payload(action: 'create_touch_plan', touch_plan: touch_plan))
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
