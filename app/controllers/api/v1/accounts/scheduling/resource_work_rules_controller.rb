class Api::V1::Accounts::Scheduling::ResourceWorkRulesController < Api::V1::Accounts::Scheduling::BaseController
  before_action :check_admin_authorization?, only: [:update]
  before_action :set_resource

  def show
    rules = @scheduling_resource.work_rules.ordered
    render_payload(rules.map { |rule| Scheduling::PayloadBuilder.work_rule(rule) }, meta: { count: rules.size })
  end

  def update
    if @scheduling_resource.inherit_working_hours_from_account?
      raise Scheduling::Error.new(
        code: 'WORK_RULES_INHERITED',
        message: 'Disable company working hours inheritance before editing specialist work rules',
        status: :unprocessable_content
      )
    end

    rules_payload = params.permit(work_rules: [:weekday, :start_minute, :end_minute, :active])[:work_rules] || []
    validate_unique_weekdays!(rules_payload)

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

  def validate_unique_weekdays!(rules_payload)
    weekdays = rules_payload.map { |rule| rule[:weekday].to_i }
    return if weekdays.uniq.size == weekdays.size

    raise Scheduling::Error.new(
      code: 'DUPLICATE_WORKDAY',
      message: 'Only one working interval is allowed per weekday',
      status: :unprocessable_content
    )
  end

  def set_resource
    @scheduling_resource = Current.account.scheduling_resources.not_deleted_from_scheduling.find(params[:resource_id])
  end
end
