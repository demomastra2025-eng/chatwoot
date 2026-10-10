class Crm::Appointments::RefreshPipelineJob < ApplicationJob
  queue_as :low
  BATCH_SIZE = 250

  def perform(account_id, pipeline_id, after_id = 0)
    pipeline = Crm::Pipeline.find_by(account_id: account_id, id: pipeline_id)
    return unless pipeline

    ids = pipeline.deals.active.where('crm_deals.id > ?', after_id).order(:id).limit(BATCH_SIZE).pluck(:id)
    ids.each { |deal_id| Crm::Appointments::EvaluateDealJob.perform_later(account_id, deal_id) }
    self.class.perform_later(account_id, pipeline_id, ids.last) if ids.length == BATCH_SIZE
  end
end
