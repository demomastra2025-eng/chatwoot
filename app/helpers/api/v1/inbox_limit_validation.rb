module Api::V1::InboxLimitValidation
  extend ActiveSupport::Concern

  private

  def validate_limit
    violation = channel_limit_violation
    return if violation.blank?

    render_payment_required("Account #{violation} limit exceeded. Upgrade to a higher plan")
  end

  def channel_limit_violation
    return 'call channel' if call_channel_limit_reached?
    return 'main channel' if main_channel_limit_reached?
    return 'channel' if text_channel_limit_reached?
  end

  def call_channel_limit_reached?
    creating_call_channel_inbox? && channel_limit_reached?(:call_inboxes, Current.account.call_channels_count)
  end

  def main_channel_limit_reached?
    creating_main_channel_inbox? && channel_limit_reached?(:non_web_inboxes, Current.account.main_channels_count)
  end

  def text_channel_limit_reached?
    !creating_call_channel_inbox? && channel_limit_reached?(:inboxes, Current.account.text_channels_count)
  end

  def channel_limit_reached?(key, consumed)
    consumed >= Current.account.usage_limits.fetch(key, ChatwootApp.max_limit).to_i
  end

  def creating_call_channel_inbox?
    permitted_params[:channel][:type] == 'voice'
  end

  def creating_main_channel_inbox?
    %w[api whatsapp telegram_personal whatsapp_web].include?(permitted_params[:channel][:type])
  end
end
