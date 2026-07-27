module Outbound::TouchPlanEnrollmentPayloadBuilder
  module_function

  def build(enrollment)
    {
      id: enrollment.id,
      status: enrollment.status,
      reminder_group_id: enrollment.reminder_group_id,
      reminder_group_name: enrollment.reminder_group&.name,
      next_due_at: enrollment.next_due_at,
      activated_at: enrollment.activated_at,
      remindable: Outbound::PayloadBuilder.remindable_payload(enrollment.remindable),
      metadata: enrollment.metadata,
      created_at: enrollment.created_at,
      updated_at: enrollment.updated_at
    }
  end
end
