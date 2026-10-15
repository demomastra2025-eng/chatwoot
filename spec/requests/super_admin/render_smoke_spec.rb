require 'rails_helper'

# Render smoke test of the whole super admin: every Administrate dashboard that
# has them gets its index, new, show and edit pages opened, and every custom
# page is opened too. The shell (sidebar, header, flashes) and the Administrate
# templates the app owns (index, show, form, new, edit, collection, filters,
# search) are shared by all of them, so one broken partial fails here.
RSpec.describe 'Super Admin render smoke', type: :request do
  # Administrate resources that have dashboards, and a record of each to open
  # its show and edit pages.
  resources = %i[accounts users account_users agent_bots installation_configs access_tokens platform_apps platform_banners]

  def build_record(resource)
    {
      accounts: -> { create(:account) },
      users: -> { create(:user) },
      account_users: -> { create(:account_user) },
      agent_bots: -> { create(:agent_bot) },
      installation_configs: -> { create(:installation_config, name: 'SMOKE_CONFIG', value: 'smoke', locked: false) },
      access_tokens: -> { create(:platform_app).access_token },
      platform_apps: -> { create(:platform_app) },
      platform_banners: -> { create(:platform_banner) }
    }.fetch(resource).call
  end

  # Only the pages a resource really has are opened (account users have no
  # index and no edit page, access tokens are read-only, ...). A path counts when
  # it is routed to the action itself and not to `show` with an id of "new".
  def self.routed?(path, action)
    Rails.application.routes.recognize_path(path, method: 'GET')[:action] == action.to_s
  rescue ActionController::RoutingError
    false
  end

  def self.pages_of(resource)
    {
      index: "/super_admin/#{resource}",
      new: "/super_admin/#{resource}/new",
      show: "/super_admin/#{resource}/1",
      edit: "/super_admin/#{resource}/1/edit"
    }.select { |action, path| routed?(path, action) }.keys
  end

  let(:super_admin) { create(:super_admin) }
  let(:submit_button) { 'main form input[type="submit"], main form button[type="submit"]' }

  def page = Nokogiri::HTML(response.body)

  def expect_shell(path)
    expect(response).to have_http_status(:ok), "GET #{path} answered #{response.status}"
    expect(page.at_css('nav[role="navigation"]')).to be_present, "GET #{path} has no sidebar"
    expect(page.at_css('main[role="main"]')).to be_present, "GET #{path} has no main area"
    expect(response.body).not_to include('translation missing'), "GET #{path} has a missing translation"
  end

  before do
    allow(ChatwootApp).to receive(:chatwoot_cloud?).and_return(true)
    sign_in(super_admin, scope: :super_admin)
  end

  resources.each do |resource|
    describe "/super_admin/#{resource}" do
      pages = pages_of(resource)

      if pages.include?(:index)
        it 'opens the index page with its table' do
          build_record(resource)
          get "/super_admin/#{resource}"

          expect_shell("/super_admin/#{resource}")
          expect(page.at_css('main h1.main-content__page-title')).to be_present
          expect(page.at_css('main .admin-card table')).to be_present
        end
      end

      if pages.include?(:new)
        it 'opens the new page with its form' do
          get "/super_admin/#{resource}/new"

          expect_shell("/super_admin/#{resource}/new")
          expect(page.at_css(submit_button)).to be_present
        end
      end

      if pages.include?(:show)
        it 'opens the show page' do
          record = build_record(resource)
          get "/super_admin/#{resource}/#{record.id}"

          if resource == :account_users
            # An account user has no page of its own; it sends you to its user.
            expect(response).to redirect_to(super_admin_user_path(record.user))
          else
            expect_shell("/super_admin/#{resource}/#{record.id}")
            expect(page.at_css('main dl.attribute-list')).to be_present
          end
        end
      end

      if pages.include?(:edit)
        it 'opens the edit page with its form' do
          record = build_record(resource)
          get "/super_admin/#{resource}/#{record.id}/edit"

          expect_shell("/super_admin/#{resource}/#{record.id}/edit")
          expect(page.at_css(submit_button)).to be_present
        end
      end
    end
  end

  describe 'custom pages' do
    {
      'dashboard' => '/super_admin',
      'general settings' => '/super_admin/app_config',
      'AI models' => '/super_admin/app_config?config=captain',
      'channel settings' => '/super_admin/app_config?config=facebook',
      'audits' => '/super_admin/audits',
      'instance settings' => '/super_admin/settings',
      'instance status' => '/super_admin/instance_status',
      'monitoring' => '/super_admin/monitoring',
      'logs' => '/super_admin/logs',
      'push diagnostics' => '/super_admin/push_diagnostics',
      'channels' => '/super_admin/channels',
      'AI analytics' => '/super_admin/captain_observability'
    }.each do |name, path|
      it "opens #{name}" do
        allow(ChatwootHub).to receive(:pricing_plan).and_return('enterprise')

        get path

        expect_shell(path)
      end
    end
  end

  describe 'filters and search of an index' do
    it 'marks the current filter and keeps the search term' do
      create(:account, name: 'Smoke clinic')

      get '/super_admin/accounts', params: { search: 'active: Smoke' }

      expect(response).to have_http_status(:ok)
      current = page.css('.segmented [aria-current="true"]')
      expect(current.size).to eq(1)
      expect(current.first['href']).to include('search=active')
      expect(page.at_css('input[type="search"]')['value']).to eq('active: Smoke')
      expect(response.body).to include('Smoke clinic')
    end

    it 'marks "all" when no filter is used, links every filter and has no emoji' do
      get '/super_admin/accounts'

      items = page.css('.segmented .segmented__item')
      expect(items.size).to eq(AccountDashboard::COLLECTION_FILTERS.size + 1)
      expect(page.css('.segmented [aria-current="true"]').map { |item| item.text.strip }).to eq([I18n.t('super_admin.shell.filter_all')])
      expect(items.map(&:text).join).not_to match(/[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]/)
    end

    it 'shows an empty state for a search without results' do
      get '/super_admin/users', params: { search: 'nobody-by-this-name' }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('super_admin.shell.empty'))
    end
  end
end
