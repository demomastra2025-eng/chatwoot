module Outbound::ToolPayloadBuilder
  module_function

  def touch_payload(action:, touch:, reason: nil)
    touch_data = Outbound::PayloadBuilder.touch_payload(touch)
    template_params = touch_data[:template_params]

    {
      action: action,
      touch_id: touch_data[:id],
      status: touch_data[:status],
      content_kind: touch_data[:content_kind],
      timing_mode: touch_data[:timing_mode],
      relative_anchor: touch_data[:relative_anchor],
      relative_offset_seconds: touch_data[:relative_offset_seconds],
      relative_time_mode: touch_data[:relative_time_mode],
      relative_time_of_day: touch_data[:relative_time_of_day],
      manual_schedule_override: touch_data[:manual_schedule_override],
      scheduled_at: touch_data[:scheduled_at],
      reminder_group_id: touch_data[:reminder_group_id],
      target_inbox_id: touch_data.dig(:target, :inbox_id),
      target_contact_id: touch_data.dig(:target, :contact_id),
      template_name: hash_value(template_params, :name),
      template_language: hash_value(template_params, :language),
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
      assistant_id: touch_plan_data[:assistant_id],
      assistant: touch_plan_data[:assistant],
      active: touch_plan_data[:active],
      archived_at: touch_plan_data[:archived_at],
      entity_kinds: touch_plan_data[:entity_kinds],
      touch_count: touch_plan_data[:touches].size,
      touch_plan: touch_plan_data
    }.compact
  end

  def apply_touch_plan_payload(result)
    touch_data = result.touches.map { |touch| Outbound::PayloadBuilder.touch_payload(touch) }
    touch_plan = result.touch_plan
    application_metadata = result.payload_metadata

    {
      action: 'apply_touch_plan',
      touch_plan_id: touch_plan&.id,
      touch_plan_name: touch_plan&.name,
      created_count: touch_data.size,
      touch_ids: touch_data.pluck(:id),
      touches: touch_data,
      meta: application_metadata.merge(count: touch_data.size)
    }.merge(application_metadata).compact
  end

  def cancel_touches_payload(result:, reason: nil)
    touch_plan = result[:touch_plan]

    {
      action: 'cancel_touches',
      found_count: result[:found_count],
      cancellable_count: result[:cancellable_count],
      cancelled_count: result[:cancelled_count],
      already_terminal_count: result[:already_terminal_count],
      skipped_count: result[:skipped_count],
      failed_count: result[:failed_count],
      remaining_open_count: result[:remaining_open_count],
      cancelled_enrollment_count: result[:cancelled_enrollment_count],
      cancelled_enrollment_ids: result[:cancelled_enrollment_ids],
      enrollment_failed_count: result[:enrollment_failed_count],
      enrollment_failures: result[:enrollment_failures],
      remaining_open_enrollment_count: result[:remaining_open_enrollment_count],
      cancelled_touch_ids: result[:cancelled_touch_ids],
      skipped_touches: result[:skipped_touches],
      failures: result[:failures],
      scope: result[:scope],
      touch_plan_id: touch_plan&.dig(:id),
      reason: result[:reason].presence || reason.presence,
      remindable: result[:remindable],
      touch_plan: touch_plan
    }.compact
  end

  def delete_touch_payload(touch_payload:)
    {
      action: 'delete_touch',
      deleted: true,
      deleted_touch_id: touch_payload[:id],
      touch_id: touch_payload[:id],
      status: touch_payload[:status],
      touch: touch_payload
    }.compact
  end

  def hash_value(hash, key)
    return if hash.blank?

    hash[key] || hash[key.to_s]
  end
end
