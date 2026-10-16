require 'rails_helper'

# Render smoke test of the whole super admin: every Administrate dashboard that
# has them gets its index, new, show and edit pages opened, and every custom
# page is opened too. The shell (sidebar, header, flashes) and the Administrate
# templates the app owns (index, show, form, new, edit, collection, filters,
# search) are shared by all of them, so one broken partial fails here. Every page is also read for English: the
# super admin is Russian only, so none of the words below may be part of what a person reads.
RSpec.describe 'Super Admin render smoke', type: :request do
  # Administrate resources that have dashboards, and a record of each to open
  # its show and edit pages.
  resources = %i[organizations accounts users account_users agent_bots installation_configs access_tokens platform_apps platform_banners]

  def build_record(resource)
    {
      organizations: -> { create(:organization, :with_requisites) },
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
    expect_no_english(path)
  end

  # What a person reads: the page without scripts, styles and the raw JSON of an audit entry.
  def reading_text
    body = page.at_css('body')
    body.css('script, style, noscript, pre').each(&:remove)
    body.text.squish
  end

  def english_ui_words = %w[Create Edit Delete Search Unlimited never ago Inherited Cancel Submit Loading]

  def expect_no_english(path)
    text = reading_text
    found = text.scan(/\b(?:#{english_ui_words.join('|')})\b/).uniq
    expect(found).to be_empty, "GET #{path} says #{found.join(', ')} in English"
    expect(text).not_to match(/[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]/), "GET #{path} has an emoji"
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
          elsif resource == :accounts
            # The clinic card is made of blocks, not of one list of attributes.
            expect_shell("/super_admin/#{resource}/#{record.id}")
            expect(page.at_css('main [data-testid="plan-block"]')).to be_present
          elsif resource == :organizations
            # The organization card is made of blocks as well.
            expect_shell("/super_admin/#{resource}/#{record.id}")
            expect(page.at_css('main [data-testid="accounts-block"]')).to be_present
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

  # Every entry of the sidebar, found by reading the sidebar itself: a page added to it later is checked too.
  describe 'every entry of the sidebar' do
    let(:own_pages) do
      get '/super_admin'
      page.css('nav[role="navigation"] a').pluck('href').uniq.select { |href| href.start_with?('/super_admin') && href != '/super_admin/logout' }
    end

    it 'opens each page for a super admin, in Russian' do
      allow(ChatwootHub).to receive(:pricing_plan).and_return('enterprise')

      pages = own_pages
      expect(pages.size).to be >= 14

      pages.each do |path|
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

    it 'opens the clinic list with every filter' do
      create(:account)

      AccountDashboard::COLLECTION_FILTERS.each_key do |filter|
        get '/super_admin/accounts', params: { search: "#{filter}:" }

        expect_shell("/super_admin/accounts?search=#{filter}:")
        expect(page.at_css('[data-testid="clinics-table"]')).to be_present
      end
    end
  end

  # The clinic list, card and forms are made of blocks that depend on the state of the clinic (plan, trial, drift,
  # status); every state has to render all of them.
  describe 'the clinic pages for a clinic in every state' do
    states = {
      'without a plan' => ->(_account) {},
      'with the base' => ->(account) { Accounts::ApplyPlan.new(account: account, modules: []).call },
      'with every module' => ->(account) { Accounts::ApplyPlan.new(account: account, modules: Accounts::Plans.module_keys).call },
      'on a trial' => ->(account) { account.activate_trial!(3) },
      'after a trial' => lambda { |account|
        account.activate_trial!(3)
        account.expire_trial!
      },
      'with the base and a trial' => lambda { |account|
        Accounts::ApplyPlan.new(account: account, modules: []).call
        account.activate_trial!(3)
      },
      'with the base after a trial' => lambda { |account|
        Accounts::ApplyPlan.new(account: account, modules: []).call
        account.activate_trial!(3)
        account.expire_trial!
      },
      'with a trial typed in by hand' => lambda { |account|
        account.update!(custom_attributes: { 'plan_type' => 'trial', 'trial_expires_at' => 2.days.from_now.iso8601 })
      },
      'on a trial and changed by hand' => lambda { |account|
        Accounts::ApplyPlan.new(account: account, modules: []).call
        account.activate_trial!(3)
        account.enable_features!('sla')
      },
      'changed by hand' => lambda { |account|
        Accounts::ApplyPlan.new(account: account, modules: %w[ai_agents]).call
        account.enable_features!('sla')
        account.disable_features!('crm')
      },
      'with limits' => ->(account) { account.update!(limits: { 'agents' => 3, 'storage_bytes' => 1.gigabyte, 'conversations' => 0 }) },
      'suspended' => ->(account) { account.update!(status: :suspended) },
      'being deleted' => ->(account) { account.update!(custom_attributes: { 'marked_for_deletion_at' => 3.days.from_now.iso8601 }) }
    }

    states.each do |name, prepare|
      it "opens the list, the card, the edit form and the plan preview for a clinic #{name}" do
        account = create(:account, name: "Clinic #{name}")
        create(:user, account: account, role: :administrator)
        create(:inbox, account: account)
        prepare.call(account)

        card = "/super_admin/accounts/#{account.id}"
        ['/super_admin/accounts', card, "#{card}/edit", '/super_admin/accounts/new'].each do |path|
          get path
          expect_shell(path)
        end

        get "/super_admin/accounts/#{account.id}/plan_preview", params: { fragment: 1, modules: %w[broadcasts] }
        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include('translation missing')
      end
    end
  end

  # The organization pages and the account pages next to them, for an organization with and without requisites, with and
  # without accounts, and for an account with and without an organization.
  describe 'the organization pages' do
    def expect_pages_open(*paths)
      paths.each do |path|
        get path
        expect_shell(path)
      end
    end

    it 'open for an organization without requisites and without accounts' do
      organization = create(:organization)

      expect_pages_open('/super_admin/organizations', "/super_admin/organizations/#{organization.id}",
                        "/super_admin/organizations/#{organization.id}/edit", '/super_admin/organizations/new')
    end

    it 'open for an organization with requisites and accounts in different states' do
      organization = create(:organization, :with_requisites)
      plain = create(:account, name: 'Without a plan', organization: organization)
      create(:user, account: plain, role: :administrator)
      with_plan = create(:account, name: 'With modules', organization: organization)
      Accounts::ApplyPlan.new(account: with_plan, modules: Accounts::Plans.module_keys).call
      create(:inbox, account: with_plan)
      create(:account, name: 'Suspended', organization: organization, status: :suspended)
      create(:account, name: 'Being deleted', organization: organization,
                       custom_attributes: { 'marked_for_deletion_at' => 3.days.from_now.iso8601 })
      create(:account, name: 'Free account')

      expect_pages_open('/super_admin/organizations', "/super_admin/organizations/#{organization.id}",
                        "/super_admin/organizations/#{organization.id}/edit")
      expect(page.css('input[name="organization[bin]"]').first['value']).to eq(organization.bin)
    end

    it 'open for a search, a sort and a search without results' do
      create(:organization, :with_requisites)

      expect_pages_open('/super_admin/organizations?search=%D0%9E%D1%80%D0%B3', '/super_admin/organizations?search=nothing-like-this',
                        '/super_admin/organizations?organization%5Border%5D=bin&organization%5Bdirection%5D=desc')
    end

    it 'keep the account cards, the list and the edit form working for an account with an organization and without one' do
      organization = create(:organization, :with_requisites)
      linked = create(:account, name: 'Linked', organization: organization)
      free = create(:account, name: 'Not linked')

      [linked, free].each do |account|
        expect_pages_open('/super_admin/accounts', "/super_admin/accounts/#{account.id}", "/super_admin/accounts/#{account.id}/edit")
      end
    end
  end
end
