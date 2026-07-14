class AddPostDeliveryActionToReminders < ActiveRecord::Migration[7.1]
  SUPPORTED_ACTION_CHECK = <<~SQL.squish.freeze
    post_delivery_action IS NULL OR (
      post_delivery_action = 'resolve_conversation' AND
      action_type = 0 AND
      repeat_mode = 0 AND
      remindable_type = 'Conversation' AND
      remindable_id IS NOT NULL AND
      conversation_id = remindable_id AND
      target_conversation_id = remindable_id
    )
  SQL

  def change
    add_column :reminders, :post_delivery_action, :string
    add_check_constraint :reminders,
                         SUPPORTED_ACTION_CHECK,
                         name: 'reminders_post_delivery_action_supported'
  end
end
