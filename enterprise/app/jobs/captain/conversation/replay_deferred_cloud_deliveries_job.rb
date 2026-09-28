class Captain::Conversation::ReplayDeferredCloudDeliveriesJob < ApplicationJob
  queue_as :scheduled_jobs

  BATCH_SIZE = 100

  def perform
    recovered = 0
    deferred_captain_messages.find_each(batch_size: BATCH_SIZE) do |message|
      message.reload
      next unless due_cloud_deferral?(message)

      # A queued job can disappear even after its enqueue marker was persisted.
      # Redis is not an outbox: periodically redispatch all due DB deferrals.
      # Duplicate jobs serialize on the delivery fence before any provider I/O.
      job = SendReplyJob.perform_later(message.id)
      raise(job&.enqueue_error || ActiveJob::EnqueueError.new('Captain Cloud deferred replay was not enqueued')) unless job&.successfully_enqueued?

      recovered += 1
      break if recovered >= BATCH_SIZE
    end
  end

  private

  def deferred_captain_messages
    Message.where(sender_type: 'Captain::Assistant', message_type: Message.message_types[:outgoing], private: false)
           .where("additional_attributes ->> 'captain_delivery_state' = 'deferred'")
  end

  def due_cloud_deferral?(message)
    return false unless message.additional_attributes.to_h['captain_delivery_state'] == 'deferred'
    return false unless message.inbox.channel.is_a?(Channel::Whatsapp) && message.inbox.channel.provider == 'whatsapp_cloud'
    return false if Whatsapp::Providers::WhatsappCloudService.delivery_outcome_unknown?(message)
    return false unless Whatsapp::Providers::WhatsappCloudService.transient_send_retry_scheduled?(message)

    next_at = message.content_attributes.to_h.deep_stringify_keys['whatsapp_cloud_send_retry_next_at']
    Time.iso8601(next_at) <= Time.current
  rescue ArgumentError, TypeError
    Rails.logger.warn("[CAPTAIN][Delivery] invalid deferred Cloud retry time message_id=#{message.id}")
    false
  end
end
