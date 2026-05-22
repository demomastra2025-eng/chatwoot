module Outbound::ToolPayloadBuilder
  module_function

  def touch_payload(action:, touch:, reason: nil)
    touch_data = Outbound::PayloadBuilder.touch_payload(touch)

    {
      action: action,
      touch_id: touch_data[:id],
      status: touch_data[:status],
      content_kind: touch_data[:content_kind],
      timing_mode: touch_data[:timing_mode],
      scheduled_at: touch_data[:scheduled_at],
      auto_cancel_on_incoming: touch_data[:auto_cancel_on_incoming],
      reason: touch_data.dig(:metadata, 'cancelled_reason').presence || reason.presence,
      touch: touch_data
    }.compact
  end

  def touch_plan_payload(action:, touch_plan:)
    touch_plan_data = Outbound::PayloadBuilder.touch_plan_payload(touch_plan)

    {
      action: action,
      touch_plan_id: touch_plan_data[:id],
      name: touch_plan_data[:name],
      active: touch_plan_data[:active],
      archived_at: touch_plan_data[:archived_at],
      entity_kinds: touch_plan_data[:entity_kinds],
      touch_count: touch_plan_data[:touches].size,
      touch_plan: touch_plan_data
    }.compact
  end

  def apply_touch_plan_payload(touches)
    touch_data = touches.map { |touch| Outbound::PayloadBuilder.touch_payload(touch) }
    touch_plan = touches.first&.reminder_group

    {
      action: 'apply_touch_plan',
      touch_plan_id: touch_plan&.id,
      created_count: touch_data.size,
      touch_ids: touch_data.pluck(:id),
      touches: touch_data,
      meta: { count: touch_data.size }
    }.compact
  end

  def cancel_touches_payload(result:, reason: nil)
    touch_plan = result[:touch_plan]

    {
      action: 'cancel_touches',
      cancelled_count: result[:cancelled_count],
      touch_plan_id: touch_plan&.dig(:id),
      reason: result[:reason].presence || reason.presence,
      remindable: result[:remindable],
      touch_plan: touch_plan
    }.compact
  end
end
