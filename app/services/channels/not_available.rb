# frozen_string_literal: true

# Raised by the creation guards when a clinic tries to connect a channel it does not have
# (see Accounts::AvailableChannels.ensure_available!). The message is the Russian line the clinic reads.
class Channels::NotAvailable < StandardError
  attr_reader :channel_key

  def initialize(channel_key)
    @channel_key = channel_key.to_s
    super(Channels::Catalog.unavailable_message(@channel_key))
  end
end
