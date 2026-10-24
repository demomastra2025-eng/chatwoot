# The services a specialist really performs, read from the visit history (see Scheduling::ResourceServiceStatsAggregator). Staff
# read the list and confirm or disable a pair; the nightly aggregation never changes a status set here.
class Api::V1::Accounts::Scheduling::ResourceServiceStatsController < Api::V1::Accounts::Scheduling::BaseController
  before_action :check_admin_authorization?, except: [:index]
  before_action :set_resource

  def index
    stats = @scheduling_resource.service_stats.includes(:service).ordered.to_a

    render_payload(stats.map { |stat| stat_payload(stat) }, meta: { count: stats.size })
  end

  def update
    stat = @scheduling_resource.service_stats.find(params[:id])
    status = params.require(:status).to_s
    unless Scheduling::ResourceServiceStat::MANUAL_STATUSES.include?(status)
      raise ArgumentError, "status must be one of #{Scheduling::ResourceServiceStat::MANUAL_STATUSES.join(', ')}"
    end

    stat.update!(status: status)
    render_payload(stat_payload(stat))
  end

  private

  def set_resource
    @scheduling_resource = Current.account.scheduling_resources.find(params[:resource_id])
  end

  def stat_payload(stat)
    {
      id: stat.id,
      resource_id: stat.resource_id,
      service_id: stat.service_id,
      service_name: stat.service.name,
      service_category: stat.service.category,
      receptions_count: stat.receptions_count,
      median_duration_min: stat.median_duration_min,
      last_seen_at: stat.last_seen_at&.iso8601,
      source: stat.source,
      status: stat.status,
      counts: Scheduling::ResourceServiceStat::USABLE_STATUSES.include?(stat.status)
    }
  end
end
