class Webhooks::TelegramController < ActionController::API
  def process_payload
    channel = Channel::Telegram.find_by(bot_token: params[:bot_token].to_s)
    return head :not_found if channel.blank?
    return head :unauthorized unless valid_secret_header?(channel)

    job_params = params.to_unsafe_hash.except('bot_token', :bot_token).merge('channel_id' => channel.id)
    Webhooks::TelegramEventsJob.perform_later(job_params)
    head :ok
  end

  private

  def valid_secret_header?(channel)
    raw_header = request.headers['X-Telegram-Bot-Api-Secret-Token']
    return !secret_token_required? if raw_header.nil?

    provided = raw_header.to_s
    expected = channel.webhook_secret_token.to_s
    provided.present? && expected.present? &&
      provided.bytesize == expected.bytesize &&
      ActiveSupport::SecurityUtils.secure_compare(provided, expected)
  end

  def secret_token_required?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch('TELEGRAM_WEBHOOK_REQUIRE_SECRET_TOKEN', false))
  end
end
