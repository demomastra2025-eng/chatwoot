class Crm::Deals::ReopenService
  def initialize(account:, deal:, params:, actor: nil)
    @account = account
    @deal = deal
    @params = params.to_h.deep_symbolize_keys
    @actor = actor
  end

  def perform
    target_stage = resolve_stage
    unless target_stage.outcome_open?
      raise Crm::Error.new(code: 'DEAL_STAGE_NOT_OPEN', message: 'Reopen target must have open outcome', status: :unprocessable_content)
    end

    Crm::Deals::TransitionService.new(
      account: @account,
      deal: @deal,
      actor: @actor,
      params: @params.merge(stage_id: target_stage.id, closing_reasons: [], command_type: 'reopen')
    ).perform
  end

  private

  def resolve_stage
    return @account.crm_stages.find(@params[:stage_id]) if @params[:stage_id].present?

    @deal.pipeline.stages.active.find_by(default: true, outcome: 'open') ||
      @deal.pipeline.stages.active.where(outcome: 'open').ordered.first!
  end
end
