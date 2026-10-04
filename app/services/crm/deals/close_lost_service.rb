class Crm::Deals::CloseLostService
  def initialize(account:, deal:, params:, actor: nil, **command_options)
    @account = account
    @deal = deal
    @params = params.to_h.deep_symbolize_keys
    @actor = actor
    @catalogs_provisioned = command_options.fetch(:catalogs_provisioned, false)
    assert_known_command_options!(command_options)
  end

  def perform
    target_stage = resolve_stage
    unless target_stage.outcome_lost?
      raise Crm::Error.new(code: 'DEAL_STAGE_NOT_LOST', message: 'Target stage must have lost outcome', status: :unprocessable_content)
    end

    Crm::Deals::TransitionService.new(
      account: @account,
      deal: @deal,
      actor: @actor,
      catalogs_provisioned: @catalogs_provisioned,
      params: @params.merge(stage_id: target_stage.id, command_type: 'close_lost')
    ).perform
  end

  private

  def assert_known_command_options!(options)
    unknown_options = options.keys - %i[catalogs_provisioned]
    raise ArgumentError, "Unknown command options: #{unknown_options.join(', ')}" if unknown_options.present?
  end

  def resolve_stage
    return @account.crm_stages.find(@params[:stage_id]) if @params[:stage_id].present?

    @deal.pipeline.stages.active.find_by!(outcome: 'lost')
  end
end
