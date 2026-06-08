class Whatsapp::TokenHealthCheckJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    Channel::Whatsapp.where(provider: 'whatsapp_cloud').find_each do |channel|
      Whatsapp::TokenHealthCheckService.new(channel).perform
    end
  end
end
