# frozen_string_literal: true

class Confirmations::DeliveryService
  def initialize(confirmation_request:, sender: nil)
    @confirmation_request = confirmation_request
    @sender = sender
  end

  def perform
    raise ArgumentError, 'conversation is required to deliver confirmation request' if confirmation_request.conversation.blank?

    payload = Confirmations::DeliveryPayloadBuilder.new(confirmation_request).message_params
    delivery_strategy = payload.delete(:delivery_strategy)
    message = Messages::MessageBuilder.new(sender, confirmation_request.conversation, payload).perform
    confirmation_request.update!(delivery_strategy: delivery_strategy, delivery_message: message)
    message
  end

  private

  attr_reader :confirmation_request, :sender
end
