class Crm::Deals::StageCommandService
  def initialize(account:, deal:, params:, actor: nil)
    @account = account
    @deal = deal
    @params = params.to_h.deep_symbolize_keys
    @actor = actor
  end

  def perform
    target_stage = @account.crm_stages.find(@params[:stage_id])
    service_class = case target_stage.outcome
                    when 'won' then Crm::Deals::CloseWonService
                    when 'lost' then Crm::Deals::CloseLostService
                    else Crm::Deals::TransitionService
                    end

    service_class.new(account: @account, deal: @deal, params: @params, actor: @actor).perform
  end
end
