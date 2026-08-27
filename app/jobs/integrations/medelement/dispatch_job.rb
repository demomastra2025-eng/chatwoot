class Integrations::Medelement::DispatchJob < ApplicationJob
  queue_as :medelement_sync

  def perform
    Integrations::Hook.where(app_id: 'medelement', status: Integrations::Hook.statuses[:enabled]).find_each do |hook|
      Integrations::Medelement::SyncJob.perform_later(hook.id)
    end
  end
end
