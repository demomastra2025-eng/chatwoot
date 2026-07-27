class AddLiveSourceToTouchPlanEnrollments < ActiveRecord::Migration[7.0]
  def up
    add_reference :touch_plan_enrollments, :automation_rule, foreign_key: true
    add_column :touch_plan_enrollments, :source_action_id, :string

    add_index :touch_plan_enrollments,
              [:account_id, :automation_rule_id, :source_action_id, :remindable_type, :remindable_id],
              unique: true,
              where: "status IN ('active', 'paused', 'completed') AND automation_rule_id IS NOT NULL",
              name: 'idx_touch_plan_enrollments_one_open_action'

    cancel_source_less_enrollments!
    backfill_reminder_group_step_ids!
    backfill_automation_action_ids!
  end

  def down
    remove_index :touch_plan_enrollments, name: 'idx_touch_plan_enrollments_one_open_action'
    remove_column :touch_plan_enrollments, :source_action_id
    remove_reference :touch_plan_enrollments, :automation_rule, foreign_key: true
  end

  private

  # Direct writes keep this data migration independent from future model callbacks.
  # rubocop:disable Rails/SkipsModelValidations
  def cancel_source_less_enrollments!
    touch_plan_enrollment_class.where(reminder_group_id: nil, automation_rule_id: nil).find_each do |enrollment|
      metadata = enrollment.metadata.to_h.deep_stringify_keys.merge(
        'cancelled_reason' => 'live_source_unavailable_during_migration',
        'cancelled_at' => Time.current.iso8601
      )
      enrollment.update_columns(status: 'cancelled', next_due_at: nil, metadata: metadata)
    end
  end

  def backfill_reminder_group_step_ids!
    reminder_group_class.find_each do |group|
      touches = Array(group.touches)
      next unless touches.all?(Hash)

      seen_step_ids = {}
      normalized_touches = touches.map do |touch|
        normalized_touch = touch.deep_stringify_keys
        step_id = normalized_touch['step_id'].to_s
        step_id = SecureRandom.uuid if step_id.blank? || seen_step_ids[step_id]
        normalized_touch['step_id'] = step_id
        seen_step_ids[step_id] = true
        normalized_touch
      end
      group.update_columns(touches: normalized_touches) if normalized_touches != touches
    end
  end

  def backfill_automation_action_ids!
    automation_rule_class.find_each do |rule|
      actions = Array(rule.actions)
      next unless actions.all?(Hash)

      seen_action_ids = {}
      normalized_actions = actions.map do |action|
        normalized_action = action.deep_stringify_keys
        next normalized_action unless normalized_action['action_name'] == 'create_touch'

        action_id = normalized_action['action_id'].to_s
        action_id = SecureRandom.uuid if action_id.blank? || seen_action_ids[action_id]
        normalized_action['action_id'] = action_id
        seen_action_ids[action_id] = true
        normalized_action
      end
      rule.update_columns(actions: normalized_actions) if normalized_actions != actions
    end
  end
  # rubocop:enable Rails/SkipsModelValidations

  def automation_rule_class
    @automation_rule_class ||= Class.new(ActiveRecord::Base) do
      self.table_name = 'automation_rules'
      self.inheritance_column = :_type_disabled
    end
  end

  def reminder_group_class
    @reminder_group_class ||= Class.new(ActiveRecord::Base) do
      self.table_name = 'reminder_groups'
      self.inheritance_column = :_type_disabled
    end
  end

  def touch_plan_enrollment_class
    @touch_plan_enrollment_class ||= Class.new(ActiveRecord::Base) do
      self.table_name = 'touch_plan_enrollments'
      self.inheritance_column = :_type_disabled
    end
  end
end
