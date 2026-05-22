class Captain::Tools::Copilot::CancelTouchService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'cancel_touch'
  end

  description 'Cancel a single draft or pending scheduled outbound touch by ID'
  param :touch_id, type: :number, desc: 'Touch ID to cancel', required: true
  param :reason, type: :string, desc: 'Optional cancellation reason', required: false

  def execute(touch_id:, reason: nil)
    touch = touch_operations.cancel_touch(touch_id: touch_id, reason: reason)

    formatted_payload(::Outbound::ToolPayloadBuilder.touch_payload(action: 'cancel_touch', touch: touch, reason: reason))
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
