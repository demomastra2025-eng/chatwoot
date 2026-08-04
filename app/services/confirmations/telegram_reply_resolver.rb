# frozen_string_literal: true

class Confirmations::TelegramReplyResolver
  pattr_initialize [:conversation!, :actor!, :inbox!, :callback_value!, { callback_query_id: nil }]

  def perform
    resolution = Confirmations::TelegramCallback.resolve(
      value: callback_value,
      account: conversation.account,
      conversation: conversation
    )
    return if resolution.blank?

    resolved_request = resolve_request(resolution)
    Confirmations::TelegramTerminalFeedbackService.new(confirmation_request: resolved_request).perform
    resolved_request
  rescue Confirmations::ExpiredRequestError, ArgumentError => e
    Rails.logger.info("Telegram confirmation callback rejected for conversation #{conversation.id}: #{e.message}")
    nil
  end

  private

  def resolve_request(resolution)
    Confirmations::ResolveService.new(
      account: conversation.account,
      confirmation_request: resolution.fetch(:confirmation_request),
      decision: resolution.fetch(:decision),
      source: 'button',
      actor: actor,
      confidence: 1.0,
      metadata: resolution_metadata
    ).perform
  end

  def resolution_metadata
    {
      channel: 'telegram',
      inbox_id: inbox.id,
      telegram_callback_query_id: callback_query_id
    }
  end
end
