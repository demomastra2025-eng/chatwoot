class Captain::Tools::Copilot::KaspiPayBaseService < Captain::Tools::Copilot::BaseAccountTool
  private

  def kaspi_pay_operations
    Captain::Tools::Operations::KaspiPayOperations.new(
      assistant: assistant,
      conversation: current_conversation,
      actor: @user
    )
  end

  def formatted_kaspi_payload(payload)
    formatted_payload(payload)
  end

  def parse_settings(latitude: nil, longitude: nil, default_payment_type: nil)
    {
      default_payment_type: default_payment_type,
      latitude: latitude,
      longitude: longitude
    }.compact
  end
end
