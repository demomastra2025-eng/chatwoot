class Captain::Tools::CancelTouchTool < Captain::Tools::BasePublicTool
  description 'Cancel a single draft or pending scheduled outbound touch by ID'
  param :touch_id, type: 'number', desc: 'Touch ID to cancel', required: true
  param :reason, type: 'string', desc: 'Optional cancellation reason', required: false

  def perform(tool_context, touch_id:, reason: nil)
    touch = operations(tool_context.state).cancel_touch(touch_id: touch_id, reason: reason)

    tool_success(data: ::Outbound::ToolPayloadBuilder.touch_payload(action: 'cancel_touch', touch: touch, reason: reason))
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
