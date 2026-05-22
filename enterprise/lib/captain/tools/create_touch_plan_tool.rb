class Captain::Tools::CreateTouchPlanTool < Captain::Tools::BasePublicTool
  description 'Create a reusable outbound touch plan with one or more scheduled touch definitions'
  param :name, type: 'string', desc: 'Touch plan name', required: true
  param :description, type: 'string', desc: 'Optional touch plan description', required: false
  param :entity_kinds, type: 'array', desc: 'Supported entity kinds: conversation, deal, task, appointment. Defaults to conversation', required: false
  param :touches, type: 'array',
                  desc: 'Array of touch definitions using touch fields such as body, content_kind, timing_mode, scheduled_at, relative_anchor, relative_offset_seconds, timezone, target_inbox_id, template_params, metadata',
                  required: true

  def perform(tool_context, name:, touches:, description: nil, entity_kinds: nil)
    touch_plan = operations(tool_context.state).create_touch_plan(
      name: name,
      description: description,
      entity_kinds: entity_kinds,
      touches: touches
    )

    tool_success(data: ::Outbound::ToolPayloadBuilder.touch_plan_payload(action: 'create_touch_plan', touch_plan: touch_plan))
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
