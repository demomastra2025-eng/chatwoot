class WhatsappWeb::EnrichHistoryMediaService
  pattr_initialize [:message!]

  def perform
    identity = Messages::HistoryMediaIdentity.new(message)
    return message if message.attachments.exists?

    job = Channels::WhatsappWeb::MediaAttachmentBackfillJob
    # Synchronous invocation keeps ActiveJob's automatic DB retries out of a
    # user-requested read. MAX_ATTEMPTS prevents the pipeline's media retry queue.
    job.new.perform(message.inbox.channel_id, message.source_id, {}, job::MAX_ATTEMPTS)
    identity.verify!(message)
    update_availability!(identity)
    message
  end

  private

  def update_availability!(identity)
    message.with_lock do
      identity.verify!(message)

      message.skip_runtime_events = true
      message.update!(content_attributes: availability_attributes)
    end
  end

  def availability_attributes
    attributes = message.content_attributes.to_h.deep_dup
    if message.attachments.exists?
      attributes.delete('history_attachment')
    else
      attributes['history_attachment'] = attributes.fetch('history_attachment', {}).merge('fetch_state' => 'unavailable')
    end
    attributes
  end
end
