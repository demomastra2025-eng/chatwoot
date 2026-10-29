class Webhooks::TelegramEventsJob < ApplicationJob
  queue_as :telegram_inbound

  def perform(params = {})
    channel_id = params[:channel_id] || params['channel_id']
    bot_token = params[:bot_token] || params['bot_token']
    return if channel_id.blank? && bot_token.blank?

    channel = find_channel(channel_id, bot_token)

    if channel_is_inactive?(channel)
      log_inactive_channel(channel)
      return
    end

    process_event_params(channel, params)
  end

  private

  def find_channel(channel_id, bot_token)
    return Channel::Telegram.find_by(id: channel_id) if channel_id.present?

    Channel::Telegram.find_by(bot_token: bot_token)
  end

  def channel_is_inactive?(channel)
    return true if channel.blank?
    return true unless channel.account.active?

    false
  end

  def log_inactive_channel(channel)
    message = if channel&.id
                "Account #{channel.account.id} is not active for channel #{channel.id}"
              else
                'Channel not found for bot_token: [REDACTED]'
              end
    Rails.logger.warn("Telegram event discarded: #{message}")
  end

  def process_event_params(channel, params)
    return unless params[:telegram] || params['telegram']

    update_event = params.dig(:telegram, :edited_message).present? ||
                   params.dig(:telegram, :edited_business_message).present? ||
                   params.dig(:telegram, :message_reaction).present?
    if update_event
      Telegram::UpdateMessageService.new(inbox: channel.inbox, params: params['telegram'].with_indifferent_access).perform
    else
      Telegram::IncomingMessageService.new(inbox: channel.inbox, params: params['telegram'].with_indifferent_access).perform
    end
  end
end
