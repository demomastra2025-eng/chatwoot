# frozen_string_literal: true

module Reminders
  # Single source of truth for whether a channel can receive an outbound
  # message through the standard Chatwoot delivery path (SendReplyJob).
  #
  # SendReplyJob silently drops messages for channels without a registered
  # send service, which left touches "completed" but undelivered. Centralizing
  # the check here lets the delivery policy, reminder validations, and the UI
  # all agree on what is supported.
  module OutboundChannelSupport
    FACEBOOK_PAGE_CLASS = 'Channel::FacebookPage'

    def self.supported?(channel)
      return false if channel.blank?
      return true if channel.class.to_s == FACEBOOK_PAGE_CLASS

      SendReplyJob::CHANNEL_SERVICES.key?(channel.class.to_s)
    end
  end
end
