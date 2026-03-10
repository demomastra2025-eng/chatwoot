class Api::V1::Accounts::Scheduling::ResourceBreakRulesController < Api::V1::Accounts::Scheduling::BaseController
  before_action :check_admin_authorization?, only: [:update]
  before_action :set_resource

  def show
    rules = @resource.break_rules.ordered
    render_payload(rules.map { |rule| Scheduling::PayloadBuilder.break_rule(rule) }, meta: { count: rules.size })
  end

  def update
    rules_payload = params.permit(break_rules: [:weekday, :start_minute, :end_minute, :title, :active])[:break_rules] || []

    ApplicationRecord.transaction do
      @resource.break_rules.destroy_all
      rules_payload.each do |item|
        @resource.break_rules.create!(item.to_h)
      end
    end

    rules = @resource.break_rules.reload.ordered
    render_payload(rules.map { |rule| Scheduling::PayloadBuilder.break_rule(rule) }, meta: { count: rules.size })
  end

  private

  def set_resource
    @resource = Current.account.scheduling_resources.find(params[:resource_id])
  end
end
