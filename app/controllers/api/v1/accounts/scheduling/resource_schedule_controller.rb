class Api::V1::Accounts::Scheduling::ResourceScheduleController < Api::V1::Accounts::Scheduling::BaseController
  before_action :check_admin_authorization?
  before_action :set_resource
  before_action :ensure_locally_managed_resource!

  def show
    @scheduling_resource.with_lock do
      render_payload(schedule_payload)
    end
  end

  def update
    contract = Scheduling::ResourceScheduleUpdateContract.new(params)
    payload = @scheduling_resource.replace_schedule!(
      inherit: contract.inherit,
      work_rules: contract.work_rules,
      break_rules: contract.break_rules,
      expected_revision: contract.expected_revision
    ) { schedule_payload }

    render_payload(payload)
  end

  private

  def schedule_payload
    @scheduling_resource.reload
    {
      resource: Scheduling::PayloadBuilder.resource(@scheduling_resource),
      schedule_revision: Scheduling::ResourceScheduleRevision.generate(@scheduling_resource),
      work_rules: @scheduling_resource.work_rules.reload.ordered.map { |rule| Scheduling::PayloadBuilder.work_rule(rule) },
      break_rules: @scheduling_resource.break_rules.reload.ordered.map { |rule| Scheduling::PayloadBuilder.break_rule(rule) }
    }
  end

  def set_resource
    @scheduling_resource = Current.account.scheduling_resources.not_deleted_from_scheduling.find(params[:resource_id])
  end
end
