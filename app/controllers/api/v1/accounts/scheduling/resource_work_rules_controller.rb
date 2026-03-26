class Api::V1::Accounts::Scheduling::ResourceWorkRulesController < Api::V1::Accounts::Scheduling::BaseController
  before_action :check_admin_authorization?, only: [:update]
  before_action :set_resource

  def show
    rules = @scheduling_resource.work_rules.ordered
    render_payload(rules.map { |rule| Scheduling::PayloadBuilder.work_rule(rule) }, meta: { count: rules.size })
  end

  def update
    rules_payload = params.permit(work_rules: [:weekday, :start_minute, :end_minute, :active])[:work_rules] || []

    ApplicationRecord.transaction do
      @scheduling_resource.work_rules.destroy_all
      rules_payload.each do |item|
        @scheduling_resource.work_rules.create!(item.to_h)
      end
    end

    rules = @scheduling_resource.work_rules.reload.ordered
    render_payload(rules.map { |rule| Scheduling::PayloadBuilder.work_rule(rule) }, meta: { count: rules.size })
  end

  private

  def set_resource
    @scheduling_resource = Current.account.scheduling_resources.not_deleted_from_scheduling.find(params[:resource_id])
  end
end
