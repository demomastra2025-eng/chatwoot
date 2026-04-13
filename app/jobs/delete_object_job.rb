class DeleteObjectJob < ApplicationJob
  queue_as :low

  BATCH_SIZE = 5_000

  def perform(object, user = nil, ip = nil)
    deletion_context = build_post_deletion_context(object)

    mark_pending_deletion(object)
    teardown_remote_dependencies(object)

    # Pre-purge heavy associations for large objects to avoid
    # timeouts & race conditions due to destroy_async fan-out.
    purge_heavy_associations(object)
    object.destroy!
    process_post_deletion_tasks(object, user, ip, deletion_context)
  end

  def process_post_deletion_tasks(object, user, ip, deletion_context = {}); end

  private

  def build_post_deletion_context(object)
    return {} unless object.is_a?(Inbox)

    {
      channel_medium: object.channel.try(:medium)
    }.compact
  end

  def heavy_associations
    {
      Account => %i[conversations contacts inboxes reporting_events],
      Inbox => %i[conversations contact_inboxes reporting_events]
    }.freeze
  end

  def purge_heavy_associations(object)
    klass = heavy_associations.keys.find { |k| object.is_a?(k) }
    return unless klass

    heavy_associations[klass].each do |assoc|
      next unless object.respond_to?(assoc)

      batch_destroy(object.public_send(assoc))
    end
  end

  def teardown_remote_dependencies(object)
    return unless object.is_a?(Inbox)
    return unless object.whatsapp_web? || object.telegram_personal?

    if object.whatsapp_web?
      object.channel&.teardown_provider_instance!
    elsif object.telegram_personal?
      object.channel&.teardown_runtime!
    end
  end

  def mark_pending_deletion(object)
    return unless object.respond_to?(:mark_pending_deletion!)

    object.mark_pending_deletion!
  end

  def batch_destroy(relation)
    relation.find_in_batches(batch_size: BATCH_SIZE) do |batch|
      batch.each(&:destroy!)
    end
  end
end

DeleteObjectJob.prepend_mod_with('DeleteObjectJob')
