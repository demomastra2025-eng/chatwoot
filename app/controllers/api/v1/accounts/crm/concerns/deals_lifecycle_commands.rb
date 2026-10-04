module Api::V1::Accounts::Crm::Concerns::DealsLifecycleCommands
  private

  def perform_waiting_command(service_class, command_params)
    authorize @deal, :transition_stage?
    deal = service_class.new(
      account: Current.account,
      deal: @deal,
      params: command_params,
      actor: Current.user
    ).perform
    render_payload(::Crm::PayloadBuilder.deal(deal))
  end

  def perform_lifecycle_command(service_class)
    authorize @deal, :transition_stage?
    deal = service_class.new(
      account: Current.account,
      deal: @deal,
      params: lifecycle_params,
      actor: Current.user
    ).perform
    render_payload(::Crm::PayloadBuilder.deal(deal))
  end

  def lifecycle_params
    params.permit(
      :stage_id,
      :position,
      :lock_version,
      :idempotency_key,
      :event_id,
      :transition_reason,
      :override,
      :override_reason,
      closing_reasons: []
    )
  end

  def waiting_params
    params.permit(
      :waiting_until,
      :waiting_reason,
      :create_wake_up_task,
      :wake_up_task_title,
      :lock_version,
      :idempotency_key
    )
  end
end
