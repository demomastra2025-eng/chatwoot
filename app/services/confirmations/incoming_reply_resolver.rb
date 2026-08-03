# frozen_string_literal: true

class Confirmations::IncomingReplyResolver
  def initialize(message:, callback_value: nil)
    @message = message
    @callback_value = callback_value
  end

  def perform
    callback_value.present? ? resolve_callback : resolve_text
  rescue Confirmations::ExpiredRequestError, ArgumentError => e
    Rails.logger.warn("Confirmation reply was not resolved: #{e.message}")
    nil
  end

  private

  attr_reader :message, :callback_value

  def resolve_callback
    Confirmations::TelegramReplyResolver.new(
      conversation: message.conversation,
      actor: message.sender,
      inbox: message.inbox,
      callback_value: callback_value
    ).perform
  end

  def resolve_text
    Confirmations::InboundTextResolver.new(
      account: message.account,
      conversation: message.conversation,
      message: message
    ).perform
  end
end
