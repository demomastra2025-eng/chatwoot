class Internal::CheckNewVersionsJob < ApplicationJob
  queue_as :scheduled_jobs

  # Asks the Hub (the vendor of the open source base) for the latest version of the base. Without ENABLE_CHATWOOT_HUB_SYNC
  # the Hub is not asked (ChatwootHub.sync_with_hub does nothing) and there is nothing to update.
  def perform
    return unless Rails.env.production?

    @instance_info = ChatwootHub.sync_with_hub
    update_version_info
  end

  private

  def update_version_info
    return if @instance_info.blank? || @instance_info['version'].blank?

    ::Redis::Alfred.set(::Redis::Alfred::LATEST_CHATWOOT_VERSION, @instance_info['version'])
  end
end

Internal::CheckNewVersionsJob.prepend_mod_with('Internal::CheckNewVersionsJob')
