class Api::V1::Accounts::Telephony::ResourcesController < Api::V1::Accounts::Telephony::BaseController
  before_action :check_admin_authorization?

  def capabilities
    render_payload(routing_service.capabilities)
  end

  def summary
    render_payload(routing_service.resources_summary)
  end

  def readiness
    render_payload(readiness_service.summary)
  end

  def applications
    render_payload(routing_service.applications)
  end

  def numbers
    render_payload(routing_service.numbers)
  end

  def number
    render_payload(routing_service.number(params.require(:number_ref)))
  end

  def trunks
    render_payload(routing_service.trunks)
  end

  def agents
    render_payload(routing_service.agents)
  end

  private

  def routing_service
    @routing_service ||= Telephony::RoutingService.new(account: Current.account)
  end

  def readiness_service
    @readiness_service ||= Telephony::ReadinessService.new(account: Current.account)
  end
end
