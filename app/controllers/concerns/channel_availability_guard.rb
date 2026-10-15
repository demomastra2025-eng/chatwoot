# Keeps a clinic from connecting a channel it does not have (the platform hides it, or the clinic's feature flag is off).
#
#   include ChannelAvailabilityGuard
#   before_action -> { ensure_channel_available!(requested_channel_key) }, only: [:create]
#
# Only for the paths that CREATE an inbox. Reauthorizing, reconnecting and editing an existing inbox never go through
# it, so an inbox that exists keeps working whatever the switches say. The answer is 403 with a Russian message:
#   { "error": "Канал «API» недоступен для вашей клиники. ...", "code": "channel_not_available",
#     "error_code": "channel_not_available", "channel": "api" }
# `code` and `error_code` carry the same value: the first is the name most endpoints use, the second the one the
# WhatsApp authorization endpoint (and its screen) reads.
module ChannelAvailabilityGuard
  extend ActiveSupport::Concern

  CODE = 'channel_not_available'.freeze

  included do
    rescue_from Channels::NotAvailable, with: :render_channel_not_available
  end

  private

  # key: a Channels::Catalog key; blank means "not a channel the catalog knows" and is left to the usual validation
  def ensure_channel_available!(key)
    return if key.blank?

    Accounts::AvailableChannels.ensure_available!(Current.account, key)
  end

  def render_channel_not_available(error)
    log_handled_error(error) if respond_to?(:log_handled_error, true)
    render json: { error: error.message, code: CODE, error_code: CODE, channel: error.channel_key }, status: :forbidden
  end
end
