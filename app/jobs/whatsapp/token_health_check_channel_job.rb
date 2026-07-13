# frozen_string_literal: true

class Whatsapp::TokenHealthCheckChannelJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform(channel_id)
    channel = Channel::Whatsapp.find_by(id: channel_id, provider: 'whatsapp_cloud')
    return if channel.blank? || !channel.account.active?

    Whatsapp::TokenHealthCheckService.new(channel).perform
  end
end
