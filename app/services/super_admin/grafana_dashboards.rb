# frozen_string_literal: true

# The Grafana dashboards the «Мониторинг» page embeds: the overview of the platform (tab «Метрики») and the logs (tab
# «Логи»). Which dashboard that is depends on the installation, so the uid is a setting of the installation
# (GRAFANA_OVERVIEW_DASHBOARD, GRAFANA_LOGS_DASHBOARD: the page of the general settings, or the environment variable of
# the same name); an installation that sets nothing gets the dashboards of the production stack it was built for.
#
# Canonical dashboards must be provisioned before this application release.
# Existing dashboard UIDs remain available to old bookmarks and rollback code.
module SuperAdmin::GrafanaDashboards
  BASE_PATH = '/monitoring/grafana'
  # The uid of a Grafana dashboard: letters, digits, dashes and underscores, at most 40 characters
  UID_FORMAT = /\A[A-Za-z0-9_-]{1,40}\z/
  DASHBOARDS = {
    overview: { config: 'GRAFANA_OVERVIEW_DASHBOARD', default: 'onelink-production-overview', refresh: '30s' },
    logs: { config: 'GRAFANA_LOGS_DASHBOARD', default: 'onelink-production-logs', refresh: '10s' }
  }.freeze
  LEGACY_UIDS = { 'crafty-production-overview' => 'onelink-production-overview',
                  'crafty-production-logs' => 'onelink-production-logs' }.freeze

  module_function

  # The configured uid; the default one when none is set or the value is not a uid (it ends up in an address)
  def uid(kind)
    dashboard = DASHBOARDS.fetch(kind)
    configured = GlobalConfigService.load(dashboard[:config], dashboard[:default]).to_s.strip
    selected = configured.match?(UID_FORMAT) ? configured : dashboard[:default]
    LEGACY_UIDS.fetch(selected, selected)
  end

  # The address of the dashboard for the last 24 hours, as it is opened in a new tab
  def path(kind)
    uid = uid(kind)
    "#{BASE_PATH}/d/#{uid}/#{uid}?orgId=1&from=now-24h&to=now&refresh=#{DASHBOARDS.fetch(kind)[:refresh]}"
  end

  # The same dashboard without Grafana's own chrome, for the frame of the page
  def embed_path(kind)
    "#{path(kind)}&kiosk=tv"
  end
end
