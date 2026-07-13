# frozen_string_literal: true

class Meta::FacebookPageCredentialHealthCheckJob < ApplicationJob
  class EnqueueError < StandardError; end

  BATCH_SIZE = 200
  MAX_JITTER_SECONDS = 5.minutes.to_i
  NEXT_BATCH_DELAY = 1.minute

  queue_as :scheduled_jobs

  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  def perform(after_id = nil)
    channels = active_channels(after_id).limit(BATCH_SIZE).to_a
    channels.each { |channel| enqueue_channel_check(channel) }
    enqueue_next_batch(channels.last.id) if channels.size == BATCH_SIZE
  end

  private

  def active_channels(after_id)
    scope = Channel::FacebookPage.joins(:account)
                                 .where(accounts: { status: Account.statuses[:active] })
                                 .order(:id)
    after_id ? scope.where('channel_facebook_pages.id > ?', after_id) : scope
  end

  def enqueue_channel_check(channel)
    delay = (channel.id % MAX_JITTER_SECONDS).seconds
    Meta::ChannelCredentialHealthCheckJob.set(wait: delay).perform_later(channel.class.name, channel.id)
  rescue StandardError => e
    secrets = Meta::CredentialDataSanitizer.channel_secrets(channel)
    message = Meta::CredentialDataSanitizer.sanitize(e.message.to_s.first(500), secrets: secrets)
    raise EnqueueError, "#{channel.class.name}##{channel.id} #{e.class}: #{message}"
  end

  def enqueue_next_batch(last_id)
    self.class.set(wait: NEXT_BATCH_DELAY).perform_later(last_id)
  end
end
