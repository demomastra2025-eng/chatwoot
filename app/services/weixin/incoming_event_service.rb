class Weixin::IncomingEventService
  pattr_initialize [:channel!, :payload!]

  def perform
    case event_name
    when 'message.created'
      Weixin::IncomingMessageService.new(channel: channel, payload: event_data).perform
    when 'runtime.updated'
      apply_runtime_update!
    else
      Rails.logger.info("[WEIXIN] Ignoring unsupported event #{event_name.inspect} for channel #{channel.id}")
    end
  end

  private

  def event_name
    payload[:event].to_s
  end

  def event_data
    payload.dig(:weixin, :data) || payload[:data] || {}
  end

  def apply_runtime_update!
    channel.apply_runtime_update!(
      connection_state: event_data[:connection_state],
      lifecycle_state: event_data[:lifecycle_state],
      last_error: event_data[:last_error],
      runtime_state: event_data[:runtime_state],
      context_token: event_data[:context_token],
      ilink_token: event_data[:ilink_token],
      provider_account_id: event_data[:provider_account_id],
      display_name: event_data[:display_name],
      last_synced_at: Time.current
    )
  end
end
