# frozen_string_literal: true

class OwnerFinance::OnecFreshSyncJob < ApplicationJob
  queue_as :low

  def perform
    OwnerFinance::OnecFreshSyncService.new.perform
  rescue StandardError => e
    Rails.logger.warn("[OwnerFinance::OnecFreshSyncJob] skipped/failed: #{e.class} #{e.message}")
  end
end
