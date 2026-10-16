require 'rails_helper'

RSpec.describe 'Super Admin sidebar', type: :request do
  let(:super_admin) { create(:super_admin) }

  before do
    allow(ChatwootApp).to receive(:chatwoot_cloud?).and_return(true)
    sign_in(super_admin, scope: :super_admin)
  end

  # Not memoized: some examples open several pages in a row.
  def page = Nokogiri::HTML(response.body)

  def nav = page.at_css('nav[role="navigation"]')

  def group(id)
    nav.at_css("[role=\"group\"][aria-labelledby=\"nav-group-#{id}\"]")
  end

  def link_texts(node)
    node.css('a').map { |link| link.text.squish }
  end

  def link(label)
    nav.css('a').find { |anchor| anchor.text.squish == label }
  end

  def current_labels
    nav.css('a[aria-current="page"]').map { |anchor| anchor.text.squish }
  end

  describe 'structure' do
    before { get '/super_admin' }

    it 'has four captioned groups in the agreed order' do
      captions = nav.css('[role="group"]').map { |node| node.at_css('span[id^="nav-group-"]').text.squish }

      expect(captions).to eq(%w[Клиники ИИ Система Дополнительно])
    end

    it 'lists the clinics, AI and system entries' do
      expect(link_texts(group('clinics'))).to eq(%w[Сводка Клиники Пользователи])
      expect(link_texts(group('ai'))).to eq(['Модели ИИ', 'AI-аналитика'])
      expect(link_texts(group('system')).first(6)).to eq(['Мониторинг', 'Логи', 'Очереди', 'Статус сервера', 'Журнал аудита', 'Push-диагностика'])
      expect(link_texts(group('system'))).to include('Настройки')
      expect(link_texts(group('extra'))).to eq(['Платформенные приложения', 'AI-боты', 'Баннеры', 'Каналы'])
    end

    it 'links every entry to its page' do
      {
        'Сводка' => '/super_admin',
        'Клиники' => '/super_admin/accounts',
        'Пользователи' => '/super_admin/users',
        'Модели ИИ' => '/super_admin/app_config?config=captain',
        'AI-аналитика' => '/super_admin/captain_observability',
        'Мониторинг' => '/super_admin/monitoring',
        'Логи' => '/super_admin/logs',
        'Статус сервера' => '/super_admin/instance_status',
        'Журнал аудита' => '/super_admin/audits',
        'Push-диагностика' => '/super_admin/push_diagnostics',
        'Настройки' => '/super_admin/settings',
        'Платформенные приложения' => '/super_admin/platform_apps',
        'AI-боты' => '/super_admin/agent_bots',
        'Баннеры' => '/super_admin/platform_banners',
        'Каналы' => '/super_admin/channels'
      }.each do |label, href|
        expect(link(label)['href']).to eq(href), "#{label} should link to #{href}"
      end
    end

    it 'sends the queues entry to Sidekiq' do
      expect(link('Очереди')['href']).to end_with('/monitoring/sidekiq')
    end

    it 'ends with the way back to the operator cabinet and the sign-out' do
      footer = nav.css('a').to_a.last(2)

      expect(footer.map { |anchor| anchor.text.squish }).to eq(['Кабинет оператора', 'Выйти'])
      expect(footer.map { |anchor| anchor['href'] }).to eq(['/app', '/super_admin/logout'])
      expect(footer.first['title']).to eq('Agent Dashboard')
    end

    it 'keeps the hidden resources out of the sidebar' do
      hrefs = nav.css('a').map { |anchor| anchor['href'] }

      expect(hrefs).not_to include(a_string_starting_with('/super_admin/access_tokens'))
      expect(hrefs).not_to include(a_string_starting_with('/super_admin/installation_configs'))
      expect(hrefs).not_to include(a_string_starting_with('/super_admin/account_users'))
    end

    it 'draws icons with Tailwind icon classes instead of the SVG sprite' do
      expect(nav.css('use')).to be_empty
      icons = nav.css('a span[class*="i-lucide-"]')
      expect(icons.size).to be >= 14
      expect(icons.map { |icon| icon['aria-hidden'] }.uniq).to eq(['true'])
    end

    it 'shows the brand, the console name and the environment badge' do
      expect(nav.text).to include('OneLink', 'Супер-админка')
      expect(nav.at_css('[data-testid="environment-badge"]').text.strip).to eq(Rails.env.upcase)
    end

    it 'keeps the environment badge on the line of the brand name, which wraps when the sidebar is too narrow for both' do
      badge = nav.at_css('[data-testid="environment-badge"]')
      line = badge.parent

      expect(line['class'].split).to include('flex', 'flex-wrap')
      expect(line.element_children.first.text.strip).to eq('OneLink')
      expect(line.element_children).to include(badge)
    end

    it 'puts the console name on a line of its own under them and truncates nothing, so nothing is cut off' do
      badge = nav.at_css('[data-testid="environment-badge"]')
      line = badge.parent
      column = line.parent
      caption = column.element_children.find { |node| node.text.strip == 'Супер-админка' }

      expect(caption).to be_present
      expect(column.element_children.index(caption)).to be > column.element_children.index(line)
      expect(column['class'].split).to include('flex-col', 'min-w-0')
      expect(badge['class'].split).to include('shrink-0', 'whitespace-nowrap')
      expect(column.css('[class~="truncate"]')).to be_empty
    end

    it 'offers the menu button for narrow screens' do
      toggle = nav.at_css('button[data-nav-toggle]')

      expect(toggle['aria-controls']).to eq('super-admin-menu')
      expect(toggle['aria-expanded']).to eq('false')
      expect(nav.at_css('#super-admin-menu')).to be_present
    end
  end

  describe 'banners' do
    it 'are listed on cloud' do
      get '/super_admin'

      expect(link('Баннеры')).to be_present
    end

    it 'are not listed on other installations' do
      allow(ChatwootApp).to receive(:chatwoot_cloud?).and_return(false)

      get '/super_admin'

      expect(link('Баннеры')).to be_nil
      expect(link_texts(group('extra'))).to eq(['Платформенные приложения', 'AI-боты', 'Каналы'])
    end
  end

  describe 'current entry' do
    let(:account) { create(:account) }
    let(:user) { create(:user) }

    it 'marks the dashboard' do
      get '/super_admin'

      expect(current_labels).to eq(['Сводка'])
    end

    it 'marks the clinics on the list, show and edit pages' do
      get '/super_admin/accounts'
      expect(current_labels).to eq(['Клиники'])

      get "/super_admin/accounts/#{account.id}"
      expect(current_labels).to eq(['Клиники'])

      get "/super_admin/accounts/#{account.id}/edit"
      expect(current_labels).to eq(['Клиники'])
    end

    it 'marks the users' do
      get "/super_admin/users/#{user.id}"

      expect(current_labels).to eq(['Пользователи'])
    end

    it 'marks the AI models page and not the settings' do
      allow(ChatwootHub).to receive(:pricing_plan).and_return('enterprise')

      get '/super_admin/app_config', params: { config: 'captain' }

      expect(current_labels).to eq(['Модели ИИ'])
      expect(nav.at_css('details').has_attribute?('open')).to be(false)
    end

    it 'marks the system pages' do
      {
        '/super_admin/monitoring' => 'Мониторинг',
        '/super_admin/logs' => 'Логи',
        '/super_admin/instance_status' => 'Статус сервера',
        '/super_admin/audits' => 'Журнал аудита',
        '/super_admin/push_diagnostics' => 'Push-диагностика',
        '/super_admin/captain_observability' => 'AI-аналитика'
      }.each do |path, label|
        get path

        expect(current_labels).to eq([label]), "#{path} should mark #{label}, marked #{current_labels}"
      end
    end

    it 'marks the extra resources' do
      get '/super_admin/platform_apps'
      expect(current_labels).to eq(['Платформенные приложения'])

      get '/super_admin/agent_bots'
      expect(current_labels).to eq(['AI-боты'])

      get '/super_admin/channels'
      expect(current_labels).to eq(['Каналы'])
    end

    it 'opens the settings list and marks the config page that is shown' do
      get '/super_admin/app_config', params: { config: 'facebook' }

      expect(nav.at_css('details').has_attribute?('open')).to be(true)
      expect(current_labels).to eq(['Facebook & Messenger'])
    end

    it 'marks the settings entry itself on the instance settings page' do
      get '/super_admin/settings'

      expect(current_labels).to eq(['Настройки'])
      expect(nav.at_css('details').has_attribute?('open')).to be(true)
    end

    it 'gives the current entry the solid brand pill' do
      get '/super_admin/users'

      expect(link('Пользователи')['class'].split).to include('bg-n-brand-solid', 'text-n-brand-contrast')
      expect(link('Клиники')['class'].split).to include('text-n-slate-11')
      expect(link('Клиники')['class'].split).not_to include('bg-n-brand-solid')
    end
  end

  describe 'settings list' do
    it 'does not repeat the AI models page that has its own entry' do
      get '/super_admin/settings'

      expect(link_texts(nav.at_css('details'))).not_to include('Captain AI')
    end
  end
end
