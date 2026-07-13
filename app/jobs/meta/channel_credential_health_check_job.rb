# frozen_string_literal: true

class Meta::ChannelCredentialHealthCheckJob < MutexApplicationJob
  class TransientProviderError < StandardError; end

  SUPPORTED_CHANNELS = {
    'Channel::Instagram' => Channel::Instagram,
    'Channel::FacebookPage' => Channel::FacebookPage
  }.freeze
  LOCK_TIMEOUT = 2.minutes

  queue_as :scheduled_jobs

  retry_on StandardError, wait: :polynomially_longer, attempts: 3
  discard_on ActiveRecord::RecordNotFound

  def perform(channel_type, channel_id)
    channel_class = SUPPORTED_CHANNELS.fetch(channel_type)
    channel = channel_class.find(channel_id)
    return unless channel.account.active?

    with_lock(lock_key(channel), LOCK_TIMEOUT) do
      result = Meta::ChannelCredentialHealthCheckService.new(channel).perform
      raise TransientProviderError, result.reason if result.transient?
    end
  end

  private

  def lock_key(channel)
    "META_CREDENTIAL_HEALTH:#{channel.class.name}:#{channel.id}"
  end
end
