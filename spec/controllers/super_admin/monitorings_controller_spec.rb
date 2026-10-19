require 'rails_helper'

# «Мониторинг»: one page in four tabs (metrics, logs, queues, server status). The pages it replaced redirect to their tab.
RSpec.describe 'Super Admin Monitoring', type: :request do
  let(:super_admin) { create(:super_admin) }

  # Not memoized: some examples open several pages in a row
  def page = Nokogiri::HTML(response.body)

  def text(node)
    node.text.squish
  end

  def frame_src(testid = nil)
    node = testid ? page.at_css("[data-testid='#{testid}'] iframe") : page.at_css('iframe')
    node['src']
  end

  def configure(name, value)
    config = InstallationConfig.find_or_initialize_by(name: name)
    config.value = value
    config.save!
    GlobalConfig.clear_cache
  end

  around do |example|
    GlobalConfig.clear_cache
    example.run
    GlobalConfig.clear_cache
  end

  describe 'GET /super_admin/monitoring' do
    context 'when it is an unauthenticated super admin' do
      it 'redirects to the sign-in' do
        get '/super_admin/monitoring'
        expect(response).to have_http_status(:redirect)
      end
    end

    context 'when it is an authenticated super admin' do
      before { sign_in(super_admin, scope: :super_admin) }

      it 'shows the metrics tab by default, with the tabs in a row and the current one marked' do
        get '/super_admin/monitoring'

        expect(response).to have_http_status(:success)
        expect(text(page.at_css('h1'))).to eq('Мониторинг')
        tabs = page.css('[data-testid="monitoring-tabs"] a')
        expect(tabs.map { |tab| text(tab) }).to eq(['Метрики', 'Логи', 'Очереди', 'Статус сервера'])
        expect(tabs.pluck('href')).to eq(%w[metrics logs queues status].map { |tab| "/super_admin/monitoring?tab=#{tab}" })
        expect(tabs.select { |tab| tab['aria-current'] == 'true' }.map { |tab| text(tab) }).to eq(['Метрики'])
        expect(response.body).not_to include('OpenRouter model catalog')
      end

      it 'shows the metrics tab for a tab nobody knows' do
        get '/super_admin/monitoring', params: { tab: 'secrets' }

        expect(page.at_css('[data-testid="monitoring-tabs"] [aria-current="true"]')['data-tab']).to eq('metrics')
        expect(frame_src).to include('/monitoring/grafana/d/crafty-production-overview/crafty-production-overview')
      end

      it 'shows the metrics tab for a tab sent as a list' do
        get '/super_admin/monitoring', params: { tab: %w[logs status] }

        expect(response).to have_http_status(:success)
        expect(page.at_css('[data-testid="monitoring-tabs"] [aria-current="true"]')['data-tab']).to eq('metrics')
      end

      it 'draws only the tab in use' do
        get '/super_admin/monitoring', params: { tab: 'logs' }

        expect(page.css('iframe').size).to eq(1)
        expect(page.at_css('[data-testid^="status-"]')).to be_nil
        expect(page.at_css('[data-testid="queue-list"]')).to be_nil
      end
    end
  end

  describe 'the metrics and logs tabs' do
    before { sign_in(super_admin, scope: :super_admin) }

    it 'embed the dashboards of the production stack when nothing is configured' do
      get '/super_admin/monitoring', params: { tab: 'metrics' }
      expect(frame_src).to start_with('/monitoring/grafana/d/crafty-production-overview/crafty-production-overview?orgId=1&from=now-24h')
      expect(frame_src).to end_with('&kiosk=tv')

      get '/super_admin/monitoring', params: { tab: 'logs' }
      expect(frame_src).to start_with('/monitoring/grafana/d/crafty-production-logs/crafty-production-logs?orgId=1&from=now-24h')
    end

    it 'embed the dashboards of the installation settings' do
      configure('GRAFANA_OVERVIEW_DASHBOARD', 'clinic-overview')
      configure('GRAFANA_LOGS_DASHBOARD', 'clinic-logs')

      get '/super_admin/monitoring', params: { tab: 'metrics' }
      expect(frame_src).to include('/monitoring/grafana/d/clinic-overview/clinic-overview?')
      expect(response.body).not_to include('crafty-production')

      get '/super_admin/monitoring', params: { tab: 'logs' }
      expect(frame_src).to include('/monitoring/grafana/d/clinic-logs/clinic-logs?')
      expect(response.body).not_to include('crafty-production')
    end

    it 'take the dashboards from the environment when the settings are empty' do
      with_modified_env GRAFANA_OVERVIEW_DASHBOARD: 'env-overview' do
        get '/super_admin/monitoring', params: { tab: 'metrics' }
      end

      expect(frame_src).to include('/monitoring/grafana/d/env-overview/env-overview?')
    end

    it 'open the dashboard in a new tab with the same address' do
      configure('GRAFANA_OVERVIEW_DASHBOARD', 'clinic-overview')

      get '/super_admin/monitoring', params: { tab: 'metrics' }

      link = page.css('[data-testid="monitoring-actions"] a').find { |node| text(node) == 'Открыть дашборд' }
      expect(link['href']).to start_with('/monitoring/grafana/d/clinic-overview/clinic-overview?')
      expect(link['href']).not_to include('kiosk')
      expect(link['target']).to eq('_blank')
      expect(link['rel']).to include('noopener')
    end

    it 'fall back to the default dashboard for a value that is not a dashboard uid' do
      configure('GRAFANA_OVERVIEW_DASHBOARD', '"><script>alert(1)</script>')

      get '/super_admin/monitoring', params: { tab: 'metrics' }

      expect(frame_src).to include('/monitoring/grafana/d/crafty-production-overview/crafty-production-overview?')
      expect(response.body).not_to include('<script>alert(1)')
    end

    it 'can be set on the page of the general settings' do
      get '/super_admin/app_config'

      expect(Nokogiri::HTML(response.body).css('[name^="app_config["]').pluck('name'))
        .to include('app_config[GRAFANA_OVERVIEW_DASHBOARD]', 'app_config[GRAFANA_LOGS_DASHBOARD]')
      expect(response.body).to include('Grafana: дашборд метрик', 'Grafana: дашборд логов')
    end
  end

  describe 'the queues tab' do
    before { sign_in(super_admin, scope: :super_admin) }

    it 'shows the figures of the queues in Russian and embeds the Sidekiq console that stays at its address' do
      get '/super_admin/monitoring', params: { tab: 'queues' }

      expect(response).to have_http_status(:success)
      labels = page.css('[data-testid="stat"] dt').map { |node| text(node) }
      expect(labels).to eq(['Выполняется', 'В очереди', 'Отложено', 'На повторе', 'Мёртвые задачи', 'Самое долгое ожидание'])
      expect(frame_src('sidekiq-frame')).to eq('/monitoring/sidekiq')
      link = page.css('[data-testid="monitoring-actions"] a').find { |node| text(node) == 'Открыть Sidekiq' }
      expect(link['href']).to eq('/monitoring/sidekiq')
      expect(link['target']).to eq('_blank')
      expect(response.body).to include('Консоль Sidekiq на английском языке')
    end

    it 'lists the queues with their size and waiting time' do
      stats = SuperAdmin::QueueStats::Result.new(
        busy: 2, enqueued: 1234, scheduled: 0, retries: 3, dead: 1, processed: 10, failed: 1,
        queues: [SuperAdmin::QueueStats::Queue.new(name: 'default', jobs: 1200, latency: 125),
                 SuperAdmin::QueueStats::Queue.new(name: 'low', jobs: 34, latency: 1)]
      )
      allow(SuperAdmin::QueueStats).to receive(:read).and_return(stats)

      get '/super_admin/monitoring', params: { tab: 'queues' }

      rows = page.css('[data-testid="queue-list"] tbody tr').map { |row| row.css('th, td').map { |cell| text(cell) } }
      expect(rows).to eq([['default', '1 200', '2 минуты'], ['low', '34', '1 секунда']])
      figures = page.css('[data-testid="stat"] dd').map { |node| text(node) }
      expect(figures).to eq(['2', '1 234', '0', '3', '1', '2 минуты'])
    end

    it 'marks dead jobs and a long wait' do
      stats = SuperAdmin::QueueStats::Result.new(
        busy: 0, enqueued: 5, scheduled: 0, retries: 0, dead: 4, processed: 0, failed: 0,
        queues: [SuperAdmin::QueueStats::Queue.new(name: 'default', jobs: 5, latency: 90)]
      )
      allow(SuperAdmin::QueueStats).to receive(:read).and_return(stats)

      get '/super_admin/monitoring', params: { tab: 'queues' }

      expect(page.css('[data-testid="stat"] dd.text-n-ruby-11').size).to eq(2)
      expect(page.at_css('[data-queue="default"] td.text-n-ruby-11')).to be_present
    end

    it 'says so, and still offers the console, when the queues cannot be read' do
      allow(Sidekiq::Stats).to receive(:new).and_raise(Redis::CannotConnectError)

      get '/super_admin/monitoring', params: { tab: 'queues' }

      expect(response).to have_http_status(:success)
      expect(text(page.at_css('[data-testid="queues-unavailable"]'))).to include('Не удалось прочитать очереди')
      expect(page.at_css('[data-testid="sidekiq-frame"] iframe')).to be_present
    end
  end

  describe 'the server status tab' do
    before { sign_in(super_admin, scope: :super_admin) }

    it 'shows the build of OneLink, PostgreSQL and Redis in blocks, named in Russian' do
      get '/super_admin/monitoring', params: { tab: 'status' }

      expect(page.css('[data-testid^="status-"]').pluck('data-testid')).to eq(%w[status-platform status-postgres status-redis])
      labels = page.css('dt.attribute-label').map { |node| text(node) }
      expect(labels).to include('Версия OneLink', 'Сборка (Git SHA)', 'Миграции базы данных', 'Подключение')
      expect(page.at_css('main').text).not_to match(/Redis alive|Postgres alive|Database Migrations|\btrue\b/)
    end

    it 'shows the version of OneLink and the build, and nothing of the base or its editions' do
      get '/super_admin/monitoring', params: { tab: 'status' }
      platform = page.at_css('[data-testid="status-platform"]')
      rows = platform.css('dt').zip(platform.css('dd')).to_h { |term, value| [text(term), text(value)] }

      expect(rows).to include('Версия OneLink' => SuperAdmin::BuildInfo.version, 'Сборка (Git SHA)' => SuperAdmin::BuildInfo.build)
      expect(rows.keys).not_to include('Редакция', 'Версия Chatwoot')
      expect(response.body).to include(GIT_HASH)
      expect(response.body).not_to match(/Chatwoot|Enterprise|Community/)
    end

    it 'says in Russian that the build is not known' do
      stub_const('GIT_HASH', 'unknown')

      get '/super_admin/monitoring', params: { tab: 'status' }

      expect(response.body).to include('не определена')
      expect(response.body).not_to include('unknown')
    end

    it 'shows sizes in Russian units and no limit as «Без лимита»' do
      redis = instance_double(Redis, ping: 'PONG', info: {
                                'redis_version' => '7.4.1', 'connected_clients' => '2', 'maxclients' => '10000',
                                'used_memory' => 3.megabytes.to_s, 'used_memory_peak' => 5.megabytes.to_s,
                                'total_system_memory' => 8.gigabytes.to_s, 'maxmemory' => '0',
                                'maxmemory_policy' => 'noeviction'
                              })
      allow(Redis).to receive(:new).and_return(redis)

      get '/super_admin/monitoring', params: { tab: 'status' }

      expect(response.body).to include('3 МБ', '5 МБ', '8 ГБ', 'Без лимита', 'noeviction')
      expect(response.body).not_to match(/\d[MG]\b/)
    end

    it 'says so when Redis does not answer' do
      allow(Redis).to receive(:new).and_raise(Redis::CannotConnectError)

      get '/super_admin/monitoring', params: { tab: 'status' }

      expect(response).to have_http_status(:success)
      expect(response.body).to include('Нет связи')
    end
  end

  describe 'the pages that became tabs' do
    it 'redirect the logs page to its tab' do
      get '/super_admin/logs'

      expect(response).to redirect_to('/super_admin/monitoring?tab=logs')
    end

    it 'redirect the server status page to its tab' do
      get '/super_admin/instance_status'

      expect(response).to redirect_to('/super_admin/monitoring?tab=status')
    end

    it 'land on a tab that needs a sign-in, so nothing is shown to a stranger' do
      get '/super_admin/logs'
      follow_redirect!

      expect(response).to have_http_status(:redirect)
      expect(response.location).to include('/super_admin/sign_in')
    end

    it 'lead a signed in super admin to the tab' do
      sign_in(super_admin, scope: :super_admin)

      get '/super_admin/instance_status'
      follow_redirect!

      expect(response).to have_http_status(:success)
      expect(Nokogiri::HTML(response.body).at_css('[data-testid="monitoring-tabs"] [aria-current="true"]')['data-tab']).to eq('status')
    end
  end
end
