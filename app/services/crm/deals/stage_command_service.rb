class Crm::Deals::StageCommandService
  def initialize(account:, deal:, params:, actor: nil, **command_options)
    @account = account
    @deal = deal
    @params = params.to_h.deep_symbolize_keys
    @actor = actor
    @catalogs_provisioned = command_options.fetch(:catalogs_provisioned, false)
    assert_known_command_options!(command_options)
  end

  def perform
    target_stage = @account.crm_stages.find(@params[:stage_id])
    service_class = case target_stage.outcome
                    when 'won' then Crm::Deals::CloseWonService
                    when 'lost' then Crm::Deals::CloseLostService
                    else Crm::Deals::TransitionService
                    end

    service_class.new(
      account: @account, deal: @deal, params: @params, actor: @actor,
      catalogs_provisioned: @catalogs_provisioned
    ).perform
  end

  private

  def assert_known_command_options!(options)
    unknown_options = options.keys - %i[catalogs_provisioned]
    raise ArgumentError, "Unknown command options: #{unknown_options.join(', ')}" if unknown_options.present?
  end
end
