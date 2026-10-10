class Crm::Appointments::PlanService < Crm::BaseWriteService
  def initialize(deal:, params:, actor:)
    @deal = deal
    super(account: deal.account, params: params, record: deal, actor: actor)
  end

  def perform
    @deal.with_lock do
      assert_lock_version!
      attributes = {}
      attributes[:appointment_plan] = normalize_plan if params.key?(:appointment_plan)
      attributes[:selected_appointment_id] = selected_id if params.key?(:selected_appointment_id)
      before = @deal.attributes.slice('appointment_plan', 'selected_appointment_id')
      Crm::Appointments::DeliveryPolicy.stamp_in_memory!(@deal)
      attributes[:appointment_automation_state] = @deal.appointment_automation_state
      @deal.update!(attributes)
      Crm::Events::Writer.record!(account: account, eventable: @deal, actor: actor, event_type: 'deal_updated',
                                 before_data: before, after_data: @deal.attributes.slice('appointment_plan', 'selected_appointment_id'),
                                 meta: { appointment_plan_changed: true })
    end
    Crm::Appointments::EvaluateDealJob.perform_later(account.id, @deal.id)
    @deal
  end

  private

  def normalize_plan
    plan = Array(params[:appointment_plan])
    raise ArgumentError, 'Appointment plan may have at most 100 required visits' if plan.length > 100

    normalized = plan.map do |entry|
      entry = entry.to_h.deep_symbolize_keys
      label = entry[:label].to_s.strip
      raise ArgumentError, 'Each planned visit requires a label' if label.blank? || label.length > 200

      id = entry[:appointment_id].presence && linked_id!(entry[:appointment_id])
      { 'id' => entry[:id].presence || SecureRandom.uuid, 'label' => label, 'required' => entry[:required] != false, 'appointment_id' => id }
    end
    raise ArgumentError, 'Each planned visit must have a distinct identity' if normalized.map { |entry| entry['id'] }.uniq.length != normalized.length

    linked_ids = normalized.filter_map { |entry| entry['appointment_id'] }
    raise ArgumentError, 'A visit can fulfill only one planned appointment' if linked_ids.uniq.length != linked_ids.length

    normalized
  end

  def selected_id
    params[:selected_appointment_id].presence && linked_id!(params[:selected_appointment_id])
  end

  def linked_id!(value)
    @deal.appointments.where(account_id: account.id).find(value).id
  end
end
