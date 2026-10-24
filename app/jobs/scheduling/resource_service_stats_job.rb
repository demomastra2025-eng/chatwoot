# Rebuilds the specialist-service pairs of the visit history (see Scheduling::ResourceServiceStatsAggregator).
#
# Without an account id (the nightly cron entry in config/schedule.yml) it queues one run per account that has an enabled MedElement
# integration; with an account id it rebuilds that account. Each run is one aggregation query and a few hundred rows, so the runs
# only need a small stagger.
#
#   Scheduling::ResourceServiceStatsJob.perform_later(account.id)
class Scheduling::ResourceServiceStatsJob < ApplicationJob
  queue_as :low

  STAGGER = 30.seconds

  discard_on ActiveRecord::RecordNotFound

  def perform(account_id = nil)
    return enqueue_runs if account_id.nil?

    Scheduling::ResourceServiceStatsAggregator.new(account: Account.find(account_id)).perform.to_h
  end

  # The accounts whose visit history carries MedElement service codes.
  def self.account_ids
    Integrations::Hook.where(app_id: 'medelement', status: 'enabled').distinct.order(:account_id).pluck(:account_id)
  end

  private

  def enqueue_runs
    self.class.account_ids.each_with_index do |account_id, index|
      self.class.set(wait: index * STAGGER).perform_later(account_id)
    end
  end
end
