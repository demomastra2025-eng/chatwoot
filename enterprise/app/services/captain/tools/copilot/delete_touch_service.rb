class Captain::Tools::Copilot::DeleteTouchService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'delete_touch'
  end

  description 'Delete a draft, pending, failed, or cancelled scheduled outbound touch by ID'
  param :touch_id, type: :number, desc: 'Touch ID to delete', required: true

  def execute(touch_id:)
    touch_payload = touch_operations.delete_touch(touch_id: touch_id)

    formatted_payload(::Outbound::ToolPayloadBuilder.delete_touch_payload(touch_payload: touch_payload))
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
