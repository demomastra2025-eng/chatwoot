# frozen_string_literal: true

class Telegram::CallbackAcknowledgementService
  pattr_initialize [:inbox!, :callback_query_id!]

  def perform
    inbox.channel.answer_callback_query(callback_query_id: callback_query_id)
  rescue StandardError => e
    Rails.logger.warn("Telegram callback acknowledgement failed for inbox #{inbox.id}: #{e.class}")
    false
  end
end
