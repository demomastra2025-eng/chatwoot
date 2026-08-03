# frozen_string_literal: true

class Telegram::IncomingReplyService
  pattr_initialize [:inbox!, :conversation!, :actor!, :params!]

  def perform
    acknowledge_callback_query
    Confirmations::TelegramReplyResolver.new(
      conversation: conversation,
      actor: actor,
      inbox: inbox,
      callback_value: callback_value,
      callback_query_id: params.dig(:callback_query, :id)
    ).perform
  end

  private

  def acknowledge_callback_query
    Telegram::CallbackAcknowledgementService.new(
      inbox: inbox,
      callback_query_id: params.dig(:callback_query, :id)
    ).perform
  end

  def callback_value
    params.dig(:callback_query, :data)
  end
end
