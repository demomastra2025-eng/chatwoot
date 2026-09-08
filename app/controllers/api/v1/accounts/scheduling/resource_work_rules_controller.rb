class Api::V1::Accounts::Scheduling::ResourceWorkRulesController < Api::V1::Accounts::Scheduling::BaseController
  before_action :check_admin_authorization?, only: [:update]
  before_action :set_resource
  before_action :ensure_locally_managed_resource!, only: [:update]

  def show
    rules = @scheduling_resource.work_rules.ordered
    render_payload(rules.map { |rule| Scheduling::PayloadBuilder.work_rule(rule) }, meta: { count: rules.size })
  end

  def update
    rules_payload = schedule_rules_payload(:work_rules, permitted: [:weekday, :start_minute, :end_minute, :active])

    @scheduling_resource.with_lock do
      @scheduling_resource.reload
      if @scheduling_resource.inherit_working_hours_from_account?
        raise Scheduling::Error.new(
          code: 'WORK_RULES_INHERITED',
          message: 'Disable company working hours inheritance before editing specialist work rules',
          status: :unprocessable_content
        )
      end

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
