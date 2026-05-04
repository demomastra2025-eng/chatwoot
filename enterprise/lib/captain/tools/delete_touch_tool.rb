class Captain::Tools::DeleteTouchTool < Captain::Tools::BasePublicTool
  description 'Delete a draft, pending, failed, or cancelled scheduled outbound touch by ID'
  param :touch_id, type: 'number', desc: 'Touch ID to delete', required: true

  def perform(tool_context, touch_id:)
    touch_payload = operations(tool_context.state).delete_touch(touch_id: touch_id)

    JSON.pretty_generate(
      action: 'delete_touch',
      deleted: true,
      deleted_touch_id: touch_payload[:id],
      touch: touch_payload
    )
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
