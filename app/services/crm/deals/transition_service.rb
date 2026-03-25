class Crm::Deals::TransitionService < Crm::BaseWriteService
  def initialize(account:, deal:, params:, actor: nil)
    @deal = deal
    super(account: account, params: params, record: @deal, actor: actor)
  end

  def perform
    ApplicationRecord.transaction do
      deal.lock!
      assert_lock_version!

      target_stage = account.crm_stages.find(params[:stage_id])
      return deal if deal.stage_id == target_stage.id

      from_stage_id = deal.stage_id
      from_pipeline_id = deal.pipeline_id

      deal.stage = target_stage
      deal.pipeline = target_stage.pipeline
      deal.closed_at = target_stage.outcome_open? ? nil : Time.zone.now
      deal.save!

      ::Crm::Events::Writer.record!(
        account: account,
        eventable: deal,
        actor: actor,
        event_type: 'deal_stage_changed',
        meta: {
          from_stage_id: from_stage_id,
          to_stage_id: target_stage.id,
          from_pipeline_id: from_pipeline_id,
          to_pipeline_id: target_stage.pipeline_id
        }
      )

      deal.reload
    end
  end

  private

  attr_reader :deal
end
