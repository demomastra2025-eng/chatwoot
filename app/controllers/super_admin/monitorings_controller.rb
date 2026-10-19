# One page for everything about how the platform is doing, in tabs: the metrics (Grafana), the logs (Grafana), the
# background queues (Sidekiq) and the state of the server. The old pages (/super_admin/logs, /super_admin/instance_status)
# redirect to their tab (config/routes.rb).
class SuperAdmin::MonitoringsController < SuperAdmin::ApplicationController
  TABS = %w[metrics logs queues status].freeze
  DEFAULT_TAB = 'metrics'.freeze

  def show
    @tab = TABS.include?(params[:tab]) ? params[:tab] : DEFAULT_TAB
    @queue_stats = SuperAdmin::QueueStats.read if @tab == 'queues'
    @status_sections = SuperAdmin::InstanceStatus.new.sections if @tab == 'status'
  end
end
