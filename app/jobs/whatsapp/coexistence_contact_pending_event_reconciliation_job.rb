class Whatsapp::CoexistenceContactPendingEventReconciliationJob < ApplicationJob
  queue_as :whatsappweb_history

  discard_on ActiveRecord::RecordNotFound

  def perform(channel_id, after_id, until_id)
    channel = Channel::Whatsapp.active_cloud.find(channel_id)
    return unless channel.provider_config.to_h['embedded_signup_flow'] == 'coexistence'

    Whatsapp::CoexistenceContactSyncService.new(
      channel: channel,
      value: {},
      pending_after_id: after_id,
      pending_until_id: until_id
    ).perform
  end
end
