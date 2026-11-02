class WhatsappWeb::EnrichHistoryMediaService
  pattr_initialize [:message!]

  def perform
    return message if message.attachments.exists?

    job = Channels::WhatsappWeb::MediaAttachmentBackfillJob
    # Synchronous invocation keeps ActiveJob's automatic DB retries out of a
    # user-requested read. MAX_ATTEMPTS prevents the pipeline's media retry queue.
    job.new.perform(message.inbox.channel_id, message.source_id, {}, job::MAX_ATTEMPTS)
    message.reload
    update_availability!
    message
  end

  private

  def update_availability!
    message.with_lock do
      return if message.inbox.reload.deleting? || message.content_attributes.to_h['deleted'].present?

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
