require 'rails_helper'

# «Организации» of the super admin: the paying parent of accounts. The list, the card, the forms, linking and unlinking
# an account and the audit entries they leave.
RSpec.describe 'Super Admin organizations', type: :request do
  let(:super_admin) { create(:super_admin) }

  # Not memoized: some examples open several pages in a row.
  def page = Nokogiri::HTML(response.body)

  def text(node) = node.text.squish

  def audits_of(record, action = nil)
    scope = Audited::Audit.where(auditable_type: record.class.name, auditable_id: record.id)
    action ? scope.where(action: action) : scope
  end

  # An account with `operators` administrators and `channels` inboxes
  def account_with(organization, name:, operators: 0, channels: 0)
    create(:account, name: name, organization: organization).tap do |account|
      create_list(:user, operators, account: account, role: :administrator)
      create_list(:inbox, channels, account: account)
    end
  end

  # Counts the SQL statements a block runs (cached reads and schema lookups do not count)
  def query_count(&)
    count = 0
    counter = ->(*, payload) { count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) || payload[:cached] }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &)
    count
  end

  describe 'for someone who is not a super admin' do
    let!(:organization) { create(:organization) }

    it 'sends the list and the card to the sign-in page' do
      get '/super_admin/organizations'
      expect(response).to have_http_status(:redirect)
      expect(response.location).to include('/super_admin/sign_in')

      get "/super_admin/organizations/#{organization.id}"
      expect(response).to have_http_status(:redirect)
      expect(response.location).to include('/super_admin/sign_in')
    end

    it 'does not create, delete or link anything' do
      post '/super_admin/organizations', params: { organization: { name: 'Чужая' } }
      expect(response).to have_http_status(:redirect)

      account = create(:account)
      post "/super_admin/organizations/#{organization.id}/link_account", params: { account_id: account.id }
      expect(response).to have_http_status(:redirect)

      delete "/super_admin/organizations/#{organization.id}"
      expect(response).to have_http_status(:redirect)

      expect(Organization.pluck(:id)).to eq([organization.id])
      expect(account.reload.organization).to be_nil
    end

    it 'does not let a signed-in operator in either' do
      sign_in(create(:user), scope: :user)

      get '/super_admin/organizations'

      expect(response).to have_http_status(:redirect)
      expect(response.location).to include('/super_admin/sign_in')
    end
  end

  context 'when a super admin is signed in' do
    before { sign_in(super_admin, scope: :super_admin) }

    describe 'the list' do
      it 'is titled «Организации», explains itself and offers a new organization' do
        get '/super_admin/organizations'

        expect(response).to have_http_status(:ok)
        expect(text(page.at_css('h1.main-content__page-title'))).to eq('Организации')
        expect(text(page.at_css('.main-content__description'))).to include('БИН')
        expect(text(page.at_css('a[href="/super_admin/organizations/new"]'))).to eq('Новая организация')
        expect(page.at_css('title').text).to include('Организации')
      end

      it 'has the agreed columns' do
        get '/super_admin/organizations'

        headers = page.css('[data-testid="organizations-table"] thead th').map { |header| text(header) }
        expect(headers).to eq(%w[Название БИН Договор Аккаунтов Операторов Каналов Создана Действия])
      end

      it 'shows an empty state when there are no organizations' do
        get '/super_admin/organizations'

        expect(response.body).to include('Ничего не найдено')
      end

      it 'shows the requisites, the contract, the totals of the accounts and the creation date in Astana time' do
        organization = create(:organization, :with_requisites, name: 'Алатау Медикал', legal_name: 'ТОО Алатау Медикал',
                                                               bin: '980140000124', created_at: Time.utc(2026, 10, 15, 20, 30))
        account_with(organization, name: 'Филиал 1', operators: 2, channels: 1)
        account_with(organization, name: 'Филиал 2', operators: 1, channels: 3)
        create(:account, name: 'Чужой аккаунт')

        get '/super_admin/organizations'

        row = page.at_css("tr[data-organization-id='#{organization.id}']")
        cells = row.css('td').map { |cell| text(cell) }
        expect(cells[0]).to eq('Алатау Медикал ТОО Алатау Медикал')
        expect(cells[1]).to eq('980140000124')
        expect(cells[2]).to eq('№ ДГ-12 от 15.03.2026')
        expect(cells[3..5]).to eq(%w[2 3 4])
        expect(cells[6]).to eq('16.10.2026')
        expect(row['data-url']).to eq("/super_admin/organizations/#{organization.id}")
        expect(row.at_css('a[href$="/edit"]')).to be_present
      end

      it 'shows a dash for what is not filled in and does not count unlinked accounts' do
        create(:organization, name: 'Без реквизитов')
        create(:account)

        get '/super_admin/organizations'

        cells = page.css('[data-testid="organizations-table"] tbody tr').first.css('td').map { |cell| text(cell) }
        expect(cells[1..5]).to eq(['—', '—', '0', '0', '0'])
      end

      it 'counts operators the way the limit counts them (excluded members stay out)' do
        organization = create(:organization)
        account = account_with(organization, name: 'Филиал', operators: 3)
        account.update!(custom_attributes: { Enterprise::Account::LIMIT_COUNTER_EXCLUDED_USER_IDS_KEY => [account.users.first.id] })

        get '/super_admin/organizations'

        cells = page.at_css("tr[data-organization-id='#{organization.id}']").css('td').map { |cell| text(cell) }
        expect(cells[4]).to eq('2')
      end

      it 'sorts by name' do
        create(:organization, name: 'Бета')
        create(:organization, name: 'Альфа')

        get '/super_admin/organizations', params: { organization: { order: 'name', direction: 'asc' } }

        names = page.css('[data-testid="organizations-table"] tbody tr td:first-child a').map { |link| text(link) }
        expect(names).to eq(%w[Альфа Бета])
        expect(page.at_css('th[aria-sort="ascending"]')).to be_present
      end

      describe 'the default order' do
        def names
          page.css('[data-testid="organizations-table"] tbody tr td:first-child a').map { |link| text(link) }
        end

        it 'is the names A to Z, whatever the case and the order of creation' do
          create(:organization, name: 'bravo')
          create(:organization, name: 'Charlie')
          create(:organization, name: 'Alpha')

          get '/super_admin/organizations'

          expect(names).to eq(%w[Alpha bravo Charlie])
        end

        it 'marks the name column as the sorted one, and its header turns the order around' do
          create(:organization, name: 'Бета')
          create(:organization, name: 'Альфа')

          get '/super_admin/organizations'

          expect(names).to eq(%w[Альфа Бета])
          header = page.at_css('th[aria-sort="ascending"]')
          expect(text(header)).to eq('Название')
          query = Rack::Utils.parse_nested_query(URI(header.at_css('a')['href']).query)
          expect(query['organization']).to eq('order' => 'name', 'direction' => 'desc')
        end

        it 'is reversed by the header, newest of the alphabet first' do
          create(:organization, name: 'Бета')
          create(:organization, name: 'Альфа')

          get '/super_admin/organizations', params: { organization: { order: 'name', direction: 'desc' } }

          expect(names).to eq(%w[Бета Альфа])
          expect(page.at_css('th[aria-sort="descending"]')).to be_present
        end

        it 'keeps organizations of the same name in a stable order, so no page repeats or loses one' do
          created = create_list(:organization, 5, name: 'Одинаковое название')

          seen = (1..3).flat_map do |number|
            get '/super_admin/organizations', params: { per_page: 2, _page: number }
            page.css('[data-testid="organizations-table"] tbody tr[data-organization-id]').pluck('data-organization-id')
          end

          expect(seen).to eq(created.map { |organization| organization.id.to_s })
        end
      end

      it 'costs the same number of queries for 2 and for 8 organizations' do
        create_list(:organization, 2).each { |organization| account_with(organization, name: "Warm #{organization.id}", operators: 1, channels: 1) }
        get '/super_admin/organizations'
        few = query_count { get '/super_admin/organizations' }

        create_list(:organization, 6).each { |organization| account_with(organization, name: "More #{organization.id}", operators: 2, channels: 2) }
        many = query_count { get '/super_admin/organizations' }

        expect(response).to have_http_status(:ok)
        expect(page.css('[data-testid="organizations-table"] tbody tr').size).to eq(8)
        expect(many).to eq(few)
      end
    end

    describe 'the numbers of the list' do
      it 'are grouped SQL: no account of the page is loaded, and the cost does not depend on the accounts either' do
        organizations = create_list(:organization, 3)
        organizations.each { |organization| account_with(organization, name: "Филиал #{organization.id}", operators: 1, channels: 1) }
        get '/super_admin/organizations'
        loads = []
        subscriber = ->(*, payload) { loads << payload[:sql] if payload[:name] == 'Account Load' }
        few = ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') { query_count { get '/super_admin/organizations' } }

        organizations.each { |organization| 12.times { |index| account_with(organization, name: "Ещё #{organization.id}-#{index}", operators: 2, channels: 2) } }
        many = query_count { get '/super_admin/organizations' }

        expect(many).to eq(few)
        expect(loads.grep(/organization_id/)).to be_empty
        row = page.css('[data-testid="organizations-table"] tbody tr[data-organization-id]').find { |tr| tr['data-organization-id'] == organizations.first.id.to_s }
        expect(row.css('td')[3..5].map { |cell| text(cell) }).to eq(%w[13 25 25])
      end
    end

    describe 'search' do
      let!(:alatau) { create(:organization, name: 'Alatau Group', bin: '980140000124') }
      let!(:nur) { create(:organization, name: 'Nur Clinic', legal_name: 'LLP Nur', bin: '010203040500') }

      def found
        page.css('[data-testid="organizations-table"] tbody tr[data-organization-id]').pluck('data-organization-id')
      end

      it 'finds an organization by name' do
        get '/super_admin/organizations', params: { search: 'alatau' }

        expect(found).to eq([alatau.id.to_s])
      end

      it 'finds an organization by BIN' do
        get '/super_admin/organizations', params: { search: '980140000124' }

        expect(found).to eq([alatau.id.to_s])
      end

      it 'finds an organization by a part of the BIN' do
        get '/super_admin/organizations', params: { search: '0203040' }

        expect(found).to eq([nur.id.to_s])
      end

      it 'finds an organization by legal name' do
        get '/super_admin/organizations', params: { search: 'LLP' }

        expect(found).to eq([nur.id.to_s])
      end

      it 'says so when nothing matches and keeps the term in the box' do
        get '/super_admin/organizations', params: { search: '999999999999' }

        expect(found).to be_empty
        expect(response.body).to include('Ничего не найдено')
        expect(page.at_css('input[type="search"]')['value']).to eq('999999999999')
      end
    end

    describe 'the card' do
      let!(:organization) do
        create(:organization, :with_requisites, name: 'Алатау Медикал', legal_name: 'ТОО Алатау Медикал', bin: '980140000124',
                                                contract_number: 'ДГ-12', contract_date: Date.new(2026, 3, 15), notes: 'Договор на год.')
      end

      it 'has the name, the id, the creation date and the actions' do
        get "/super_admin/organizations/#{organization.id}"

        expect(response).to have_http_status(:ok)
        expect(text(page.at_css('h1'))).to eq('Алатау Медикал')
        expect(text(page.at_css('[data-testid="organization-meta"]'))).to include("##{organization.id}", 'создана')
        expect(page.at_css("a[href='/super_admin/organizations/#{organization.id}/edit']")).to be_present
        expect(page.at_css("form[action='/super_admin/organizations/#{organization.id}'] input[name='_method'][value='delete']")).to be_present
        expect(response.body).not_to include('translation missing')
      end

      it 'has the blocks «Реквизиты», «Договор» and «Аккаунты»' do
        get "/super_admin/organizations/#{organization.id}"

        requisites = text(page.at_css('[data-testid="requisites-block"]'))
        expect(requisites).to include('Реквизиты', 'Юридическое название', 'ТОО Алатау Медикал', 'БИН', '980140000124', 'Адрес',
                                      'Алматы, ул. Абая, 1', 'Телефон', 'E-mail для счетов', 'billing@example.test')
        contract = text(page.at_css('[data-testid="contract-block"]'))
        expect(contract).to include('Договор', 'Номер', 'ДГ-12', 'Дата', '15.03.2026', 'Заметки', 'Договор на год.')
        expect(text(page.at_css('[data-testid="accounts-block"] h2'))).to eq('Аккаунты')
      end

      it 'lets the key of a narrow side block stand over a long value (the e-mail is not broken in the middle of a word)' do
        organization.update!(billing_email: 'accounting.department@a-very-long-company-name.example.test')

        get "/super_admin/organizations/#{organization.id}"

        %w[requisites-block contract-block].each do |block|
          expect(page.at_css("[data-testid=\"#{block}\"] dl.admin-kv.admin-kv--stackable")).to be_present
        end
        expect(text(page.at_css('[data-testid="requisites-block"]'))).to include('accounting.department@a-very-long-company-name.example.test')
      end

      it 'shows a dash for requisites that are not filled in' do
        bare = create(:organization, name: 'Без реквизитов')

        get "/super_admin/organizations/#{bare.id}"

        expect(text(page.at_css('[data-testid="requisites-block"]'))).to include('—')
        expect(text(page.at_css('[data-testid="contract-block"]'))).to include('—')
      end

      # The card of an organization with two accounts (one with a plan, one suspended) next to an account of nobody
      def open_card_with_accounts
        Accounts::ApplyPlan.new(account: account_with(organization, name: 'Филиал 1', operators: 2, channels: 1), modules: []).call
        account_with(organization, name: 'Филиал 2', operators: 1, channels: 3).update!(limits: { 'agents' => 1 }, status: :suspended)
        create(:account, name: 'Чужой аккаунт')

        get "/super_admin/organizations/#{organization.id}"
        page.css('[data-testid="accounts-block"] tbody tr').map { |row| row.css('td').map { |cell| text(cell) } }
      end

      it 'lists the accounts of the organization only, by name, each linking to its account' do
        cells = open_card_with_accounts

        expect(cells.size).to eq(2)
        expect(cells.first[0]).to include('Филиал 1')
        expect(page.at_css('[data-testid="accounts-block"] tbody td a')['href']).to start_with('/super_admin/accounts/')
        expect(response.body).not_to include('Чужой аккаунт</a>')
      end

      it 'shows the plan chips, the operators used and their limit, the channels and the status of each account' do
        first, second = open_card_with_accounts

        expect(first[1]).to include('База')
        expect(first[2]).to start_with('2')
        expect(first[3]).to eq('1')
        expect(first[4]).to eq('Активен')
        expect(second[2..4]).to eq(['1 / 1', '3', 'Заблокирован'])
      end

      it 'adds up the operators, their limits and the channels in the totals row' do
        account_with(organization, name: 'Филиал 1', operators: 2, channels: 1).update!(limits: { 'agents' => 5 })
        account_with(organization, name: 'Филиал 2', operators: 1, channels: 3).update!(limits: { 'agents' => 2 })

        get "/super_admin/organizations/#{organization.id}"

        expect(text(page.at_css('[data-testid="accounts-totals"]'))).to eq('Итого 3 / 7 4')
      end

      it 'does not add up the limits when an account has none' do
        account_with(organization, name: 'Филиал 1', operators: 2, channels: 1).update!(limits: { 'agents' => 5 })
        account_with(organization, name: 'Филиал 2', operators: 1, channels: 3)
        GlobalConfig.clear_cache

        get "/super_admin/organizations/#{organization.id}"

        expect(text(page.at_css('[data-testid="accounts-totals"]'))).to eq('Итого 3 4')
      end

      describe 'the accounts block with many accounts' do
        def rows = page.css('[data-testid="accounts-block"] tbody tr[data-account-id]')

        # «Филиал 01» ... in the order of the names; each has one operator and (the first ten) one channel
        def fill(count)
          Array.new(count) { |index| account_with(organization, name: format('Филиал %<number>02d', number: index + 1), operators: 1, channels: index < 10 ? 1 : 0) }
        end

        it 'shows 25 accounts to a page with a Russian pager, and the rest on the next page' do
          fill(30)

          get "/super_admin/organizations/#{organization.id}"
          expect(rows.size).to eq(25)
          expect(text(rows.first)).to include('Филиал 01')
          expect(text(rows.last)).to include('Филиал 25')
          pager = page.at_css('[data-testid="accounts-pager"]')
          expect(text(pager)).to include('Страница 1 из 2', 'Следующая')
          expect(pager.at_css('a[rel="next"]')['href']).to include("/super_admin/organizations/#{organization.id}?accounts_page=2")

          get "/super_admin/organizations/#{organization.id}", params: { accounts_page: 2 }
          expect(rows.map { |row| text(row.at_css('td')) }).to eq((26..30).map { |number| "Филиал #{number} ##{Account.find_by(name: "Филиал #{number}").id}" })
          expect(text(page.at_css('[data-testid="accounts-pager"]'))).to include('Страница 2 из 2')
        end

        it 'has no pager for 25 accounts and keeps the plain «Итого»' do
          fill(25)

          get "/super_admin/organizations/#{organization.id}"

          expect(rows.size).to eq(25)
          expect(page.at_css('[data-testid="accounts-pager"]')).to be_nil
          expect(text(page.at_css('[data-testid="accounts-totals"] th'))).to eq('Итого')
        end

        it 'adds up all the accounts in the totals row on every page, and says so' do
          fill(30)
          GlobalConfig.clear_cache

          [{}, { accounts_page: 2 }].each do |params|
            get "/super_admin/organizations/#{organization.id}", params: params
            totals = page.at_css('[data-testid="accounts-totals"]')
            expect(text(totals.at_css('th'))).to eq('Итого по всем аккаунтам')
            expect(text(totals)).to end_with('30 10')
            expect(text(page.at_css('[data-testid="accounts-block"] h2 + span'))).to start_with('30 аккаунт')
          end
        end

        it 'shows the last page for a page past the end and the first for a page that is not a number' do
          fill(30)

          get "/super_admin/organizations/#{organization.id}", params: { accounts_page: 99 }
          expect(rows.size).to eq(5)
          expect(text(page.at_css('[data-testid="accounts-pager"]'))).to include('Страница 2 из 2')

          get "/super_admin/organizations/#{organization.id}", params: { accounts_page: 'abc' }
          expect(rows.size).to eq(25)

          get "/super_admin/organizations/#{organization.id}", params: { accounts_page: ['1'] }
          expect(response).to have_http_status(:ok)
          expect(rows.size).to eq(25)
        end

        it 'costs the same number of queries for 30 and for 70 accounts' do
          fill(30)
          get "/super_admin/organizations/#{organization.id}"
          few = query_count { get "/super_admin/organizations/#{organization.id}" }

          40.times { |index| create(:account, name: "Ещё #{index}", organization: organization) }
          many = query_count { get "/super_admin/organizations/#{organization.id}" }

          expect(response).to have_http_status(:ok)
          expect(many).to eq(few)
        end
      end

      describe 'the picker of the account to link' do
        def form = page.at_css("[data-testid='link-account'] form[action='/super_admin/organizations/#{organization.id}/link_account']")

        def search = page.at_css("[data-testid='link-account-search']")

        def options = page.css("[data-testid='link-account'] select[name='account_id'] option").reject { |option| option['value'].blank? }

        it 'is a search field on the card, sent as a GET' do
          create(:account, name: 'Свободный')

          get "/super_admin/organizations/#{organization.id}"

          expect(search['method']).to eq('get')
          expect(search['action']).to eq("/super_admin/organizations/#{organization.id}")
          expect(text(search.at_css('label'))).to eq('Найти аккаунт без организации')
          expect(search.at_css('input[name="account_search"]')['maxlength']).to eq('100')
          expect(search.at_css('input[type="submit"]')['value']).to eq('Найти')
        end

        it 'shows at most 20 of the free accounts, however many there are, and says the search has to be narrower' do
          Array.new(45) { |index| create(:account, name: format('Свободный %<number>02d', number: index + 1)) }

          get "/super_admin/organizations/#{organization.id}"

          expect(options.size).to eq(20)
          expect(text(options.first)).to start_with('Свободный 01')
          expect(text(options.last)).to start_with('Свободный 20')
          expect(text(page.at_css('[data-testid="more-matches"]'))).to eq('Показаны первые 20 совпадений. Чтобы найти другой аккаунт, уточните запрос.')
        end

        it 'does not say that when everything is shown' do
          Array.new(3) { |index| create(:account, name: "Свободный #{index}") }

          get "/super_admin/organizations/#{organization.id}"

          expect(options.size).to eq(3)
          expect(page.at_css('[data-testid="more-matches"]')).to be_nil
        end

        it 'finds an account by a part of its name and keeps the term in the field' do
          wanted = create(:account, name: 'Clinic Alatau')
          create(:account, name: 'Clinic Nur')

          get "/super_admin/organizations/#{organization.id}", params: { account_search: 'alatau' }

          expect(options.pluck('value')).to eq([wanted.id.to_s])
          expect(search.at_css('input[name="account_search"]')['value']).to eq('alatau')
        end

        it 'finds an account by its number' do
          wanted = create(:account, name: 'Номер')
          create(:account, name: 'Другой')

          get "/super_admin/organizations/#{organization.id}", params: { account_search: "##{wanted.id}" }

          expect(options.pluck('value')).to eq([wanted.id.to_s])
        end

        it 'never offers an account of an organization, found or not' do
          taken = account_with(create(:organization), name: 'Чужой аккаунт')
          mine = account_with(organization, name: 'Мой аккаунт')
          create(:account, name: 'Свободный')

          get "/super_admin/organizations/#{organization.id}", params: { account_search: 'аккаунт' }

          expect(options).to be_empty
          expect(text(page.at_css('[data-testid="no-matches"]'))).to include('ничего не найдено')

          get "/super_admin/organizations/#{organization.id}", params: { account_search: "##{taken.id}" }
          expect(options).to be_empty
          get "/super_admin/organizations/#{organization.id}", params: { account_search: "##{mine.id}" }
          expect(options).to be_empty
        end

        it 'keeps the search form when nothing matches, so that it can be changed' do
          create(:account, name: 'Свободный')

          get "/super_admin/organizations/#{organization.id}", params: { account_search: 'нет такого' }

          expect(form).to be_nil
          expect(search).to be_present
          expect(search.at_css('input[name="account_search"]')['value']).to eq('нет такого')
        end

        it 'takes a search that is not text for no search' do
          create(:account, name: 'Свободный')

          get "/super_admin/organizations/#{organization.id}", params: { account_search: ['а'] }

          expect(response).to have_http_status(:ok)
          expect(options.size).to eq(1)
        end

        it 'does not read every free account: the cost is the same for 30 and for 90 free accounts' do
          Array.new(30) { |index| create(:account, name: "Свободный #{index}") }
          get "/super_admin/organizations/#{organization.id}"
          few = query_count { get "/super_admin/organizations/#{organization.id}" }

          Array.new(60) { |index| create(:account, name: "Ещё свободный #{index}") }
          many = query_count { get "/super_admin/organizations/#{organization.id}" }

          expect(options.size).to eq(20)
          expect(many).to eq(few)
        end

        it 'posts the chosen account to link_account' do
          chosen = create(:account, name: 'Выбранный')

          get "/super_admin/organizations/#{organization.id}", params: { account_search: 'Выбран' }
          post form['action'], params: { account_id: options.first['value'] }

          expect(chosen.reload.organization).to eq(organization)
        end
      end

      it 'says so when there are no accounts and has no totals row' do
        get "/super_admin/organizations/#{organization.id}"

        expect(text(page.at_css('[data-testid="accounts-block"]'))).to include('К организации не привязан ни один аккаунт.')
        expect(page.at_css('[data-testid="accounts-totals"]')).to be_nil
      end

      it 'offers «Отвязать» for each account, asking first' do
        account = account_with(organization, name: 'Филиал 1')

        get "/super_admin/organizations/#{organization.id}"

        form = page.at_css("[data-testid='accounts-block'] form[action='/super_admin/organizations/#{organization.id}/unlink_account']")
        expect(form.at_css('input[name="account_id"]')['value']).to eq(account.id.to_s)
        expect(form.at_css('input[name="_method"]')['value']).to eq('delete')
        button = form.at_css('button[type="submit"], input[type="submit"]')
        expect(button.text.squish.presence || button['value']).to eq('Отвязать')
        expect(button['data-confirm']).to include('Филиал 1', organization.name)
      end

      it 'offers only the accounts without an organization in the select to link' do
        free = create(:account, name: 'Свободный аккаунт')
        taken = account_with(create(:organization), name: 'Чужой аккаунт')
        mine = account_with(organization, name: 'Мой аккаунт')

        get "/super_admin/organizations/#{organization.id}"

        form = page.at_css("form[action='/super_admin/organizations/#{organization.id}/link_account']")
        values = form.css('select[name="account_id"] option').pluck('value')
        expect(values).to include(free.id.to_s)
        expect(values).not_to include(taken.id.to_s, mine.id.to_s)
        expect(text(form.at_css('label'))).to eq('Аккаунт без организации')
        expect(form.at_css('input[type="submit"]')['value']).to eq('Привязать аккаунт')
      end

      it 'has no select when every account already has an organization' do
        mine = create(:organization)
        account_with(mine, name: 'Единственный')

        get "/super_admin/organizations/#{mine.id}"

        expect(page.at_css('form[action$="/link_account"]')).to be_nil
        expect(text(page.at_css('[data-testid="link-account"]'))).to include('Все аккаунты уже привязаны')
      end
    end

    describe 'creating' do
      it 'shows the form with a Russian title' do
        get '/super_admin/organizations/new'

        expect(response).to have_http_status(:ok)
        expect(text(page.at_css('h1'))).to eq('Новая организация')
        expect(page.at_css('input[type="submit"]')['value']).to eq('Создать')
        expect(response.body).not_to include('translation missing')
      end

      it 'labels the fields in Russian, in two sections, with the BIN hint' do
        get '/super_admin/organizations/new'

        labels = page.css('label').map { |label| text(label) }
        expect(labels).to include('Название', 'Юридическое название', 'БИН', 'Адрес', 'Телефон', 'E-mail для счетов', 'Номер договора',
                                  'Дата договора', 'Заметки')
        expect(page.css('legend').map { |legend| text(legend) }).to eq(%w[Реквизиты Договор])
        expect(page.css('.field-unit__hint').map { |hint| text(hint) }).to include('12 цифр')
        expect(page.at_css('input[type="date"][name="organization[contract_date]"]')).to be_present
        expect(page.at_css('textarea[name="organization[notes]"]')).to be_present
      end

      it 'saves the organization, normalizes the BIN and records the creation' do
        expect do
          post '/super_admin/organizations', params: { organization: {
            name: 'ТОО Алатау', legal_name: 'ТОО Алатау Медикал', bin: '9801 4000 0124', contract_number: 'ДГ-12',
            contract_date: '2026-03-15', billing_email: 'billing@example.test', phone: '+7 727 000 00 00', address: 'Алматы', notes: 'Заметка'
          } }
        end.to change(Organization, :count).by(1)

        organization = Organization.last
        expect(response).to redirect_to("/super_admin/organizations/#{organization.id}")
        expect(organization).to have_attributes(name: 'ТОО Алатау', bin: '980140000124', contract_date: Date.new(2026, 3, 15),
                                                billing_email: 'billing@example.test')
        follow_redirect!
        expect(page.at_css('.flashes').text).to include('Организация создана.')

        audit = audits_of(organization, 'create').sole
        expect(audit.user).to eq(super_admin)
        expect(audit.comment).to eq('super_admin')
        expect(audit.audited_changes).to include('name' => 'ТОО Алатау', 'bin' => '980140000124', 'contract_number' => 'ДГ-12')
      end

      it 'does not save a form without a name and says so in Russian' do
        expect do
          post '/super_admin/organizations', params: { organization: { name: '', bin: '12345' } }
        end.not_to change(Organization, :count)

        expect(response).to have_http_status(422)
        message = text(page.at_css('#error_explanation'))
        expect(message).to include('Название не может быть пустым', 'БИН должен состоять из 12 цифр')
        expect(page.at_css('input[name="organization[bin]"]')['value']).to eq('12345')
        expect(Audited::Audit.where(auditable_type: 'Organization')).to be_empty
      end

      it 'does not save a BIN that another organization already has' do
        create(:organization, bin: '980140000124')

        expect do
          post '/super_admin/organizations', params: { organization: { name: 'Двойник', bin: '980140000124' } }
        end.not_to change(Organization, :count)

        expect(response).to have_http_status(422)
        expect(text(page.at_css('#error_explanation'))).to include('БИН уже указан у другой организации')
      end

      it 'does not take the e-mail for billing when it is not an address' do
        post '/super_admin/organizations', params: { organization: { name: 'Почта', billing_email: 'nope' } }

        expect(response).to have_http_status(422)
        expect(text(page.at_css('#error_explanation'))).to include('E-mail для счетов указан неверно')
      end
    end

    describe 'editing' do
      let!(:organization) { create(:organization, :with_requisites, name: 'Старое название', bin: '980140000124', phone: '111') }

      it 'shows the form filled in' do
        get "/super_admin/organizations/#{organization.id}/edit"

        expect(response).to have_http_status(:ok)
        expect(page.at_css('input[name="organization[name]"]')['value']).to eq('Старое название')
        expect(page.at_css('input[name="organization[bin]"]')['value']).to eq('980140000124')
        expect(page.at_css('input[name="organization[contract_date]"]')['value']).to eq('2026-03-15')
        expect(page.at_css('input[type="submit"]')['value']).to eq('Сохранить')
      end

      it 'saves the change and records what changed' do
        patch "/super_admin/organizations/#{organization.id}", params: { organization: { name: 'Новое название', phone: '222', bin: '980140000124' } }

        expect(response).to redirect_to("/super_admin/organizations/#{organization.id}")
        expect(organization.reload).to have_attributes(name: 'Новое название', phone: '222')
        follow_redirect!
        expect(page.at_css('.flashes').text).to include('Организация сохранена.')

        audit = audits_of(organization, 'update').sole
        expect(audit.user).to eq(super_admin)
        expect(audit.audited_changes).to eq('name' => ['Старое название', 'Новое название'], 'phone' => %w[111 222])
      end

      it 'leaves no audit entry when nothing changed' do
        patch "/super_admin/organizations/#{organization.id}", params: { organization: { name: 'Старое название' } }

        expect(response).to redirect_to("/super_admin/organizations/#{organization.id}")
        expect(audits_of(organization, 'update')).to be_empty
      end

      it 'does not save an invalid BIN and keeps the old data' do
        patch "/super_admin/organizations/#{organization.id}", params: { organization: { bin: '12' } }

        expect(response).to have_http_status(422)
        expect(text(page.at_css('#error_explanation'))).to include('БИН должен состоять из 12 цифр')
        expect(organization.reload.bin).to eq('980140000124')
        expect(audits_of(organization)).to be_empty
      end

      it 'clears a requisite that was emptied' do
        patch "/super_admin/organizations/#{organization.id}", params: { organization: { bin: '', phone: '' } }

        expect(organization.reload).to have_attributes(bin: nil, phone: nil)
        expect(audits_of(organization, 'update').sole.audited_changes).to eq('bin' => ['980140000124', nil], 'phone' => ['111', nil])
      end
    end

    describe 'deleting' do
      it 'deletes an organization without accounts and records it' do
        organization = create(:organization, name: 'Лишняя', bin: '980140000124')

        expect { delete "/super_admin/organizations/#{organization.id}" }.to change(Organization, :count).by(-1)

        expect(response).to redirect_to('/super_admin/organizations')
        follow_redirect!
        expect(page.at_css('.flashes').text).to include('Организация удалена.')
        audit = audits_of(organization, 'destroy').sole
        expect(audit.user).to eq(super_admin)
        expect(audit.audited_changes).to include('name' => 'Лишняя', 'bin' => '980140000124')
      end

      it 'refuses while accounts are linked, says so in Russian and leaves everything as it was' do
        organization = create(:organization)
        account = account_with(organization, name: 'Филиал')
        other = account_with(organization, name: 'Второй филиал')

        expect { delete "/super_admin/organizations/#{organization.id}" }.not_to change(Organization, :count)

        expect(response).to redirect_to("/super_admin/organizations/#{organization.id}")
        follow_redirect!
        expect(page.at_css('.flashes').text).to include('Организацию нельзя удалить: к ней привязано 2 аккаунта. Сначала отвяжите их.')
        expect([account, other].map { |record| record.reload.organization }).to eq([organization, organization])
        expect(audits_of(organization, 'destroy')).to be_empty
      end

      it 'says «привязан 1 аккаунт» for one account' do
        organization = create(:organization)
        account_with(organization, name: 'Филиал')

        delete "/super_admin/organizations/#{organization.id}"
        follow_redirect!

        expect(page.at_css('.flashes').text).to include('к ней привязан 1 аккаунт. Сначала отвяжите его.')
      end
    end

    describe 'linking an account' do
      let!(:organization) { create(:organization, name: 'Алатау') }
      let!(:account) { create(:account, name: 'Филиал 1') }

      def link(target = organization, account_id: account.id)
        post "/super_admin/organizations/#{target.id}/link_account", params: { account_id: account_id }
      end

      it 'links the account and says so' do
        link

        expect(response).to redirect_to("/super_admin/organizations/#{organization.id}")
        expect(account.reload.organization).to eq(organization)
        follow_redirect!
        expect(page.at_css('.flashes').text).to include('Аккаунт «Филиал 1» привязан к организации.')
        expect(page.at_css('[data-testid="accounts-block"] tbody tr')['data-account-id']).to eq(account.id.to_s)
      end

      it 'records the link on both sides' do
        link

        account_audit = audits_of(account, 'link_organization').sole
        expect(account_audit.user).to eq(super_admin)
        expect(account_audit.comment).to eq('super_admin')
        expect(account_audit.audited_changes).to eq('organization_id' => [nil, organization.id], 'organization_name' => [nil, 'Алатау'])
        organization_audit = audits_of(organization, 'link_account').sole
        expect(organization_audit.user).to eq(super_admin)
        expect(organization_audit.audited_changes).to eq('account_id' => account.id, 'account_name' => 'Филиал 1')
      end

      it 'writes nothing but the link: no automatic audit entry and the plan is untouched' do
        Accounts::ApplyPlan.new(account: account, modules: %w[ai_agents]).call
        before = account.reload.attributes.except('organization_id', 'updated_at')
        updates = -> { audits_of(account, 'update').count }
        updates_before = updates.call

        link

        expect(account.reload.attributes.except('organization_id', 'updated_at')).to eq(before)
        expect(updates.call).to eq(updates_before)
      end

      it 'links an account whose old data would not pass the validations of an account today' do
        account.update_columns(settings: { 'reporting_timezone' => 'Not/AZone' }) # rubocop:disable Rails/SkipsModelValidations

        link

        expect(account.reload.organization).to eq(organization)
      end

      it 'says so and records nothing when the account is already linked here' do
        link
        Audited::Audit.delete_all

        link

        expect(response).to redirect_to("/super_admin/organizations/#{organization.id}")
        follow_redirect!
        expect(page.at_css('.flashes').text).to include('уже привязан к этой организации')
        expect(Audited::Audit.count).to eq(0)
      end

      it 'refuses an account of another organization and keeps it where it is' do
        other = create(:organization, name: 'Нур')
        account.update!(organization: other)

        link

        follow_redirect!
        expect(page.at_css('.flashes').text).to include('Аккаунт «Филиал 1» уже привязан к организации «Нур». Сначала отвяжите его там.')
        expect(account.reload.organization).to eq(other)
        expect(audits_of(account, 'link_organization')).to be_empty
      end

      # The select was drawn while the account was free; `stale` is the account as that page saw it. Another super admin
      # changes the holder between the page and this request, so the controller reads the stale record.
      def serve_stale(stale)
        allow(Account).to receive(:find_by).and_call_original
        allow(Account).to receive(:find_by).with(id: stale.id.to_s).and_return(stale)
      end

      it 'refuses an account that was linked to another organization after the page was drawn, and changes nothing' do
        other = create(:organization, name: 'Нур')
        stale = Account.find(account.id)
        account.update_columns(organization_id: other.id) # rubocop:disable Rails/SkipsModelValidations
        serve_stale(stale)

        link

        follow_redirect!
        expect(page.at_css('.flashes').text).to include('Аккаунт «Филиал 1» уже привязан к организации «Нур». Сначала отвяжите его там.')
        expect(account.reload.organization).to eq(other)
        expect(Audited::Audit.where(action: %w[link_organization unlink_organization link_account unlink_account])).to be_empty
      end

      it 'says it is already linked here when the account was linked to this organization after the page was drawn' do
        stale = Account.find(account.id)
        account.update_columns(organization_id: organization.id) # rubocop:disable Rails/SkipsModelValidations
        serve_stale(stale)

        link

        follow_redirect!
        expect(page.at_css('.flashes').text).to include('уже привязан к этой организации')
        expect(Audited::Audit.where(action: %w[link_organization link_account])).to be_empty
      end

      it 'asks to choose an account when none is sent or the number is unknown' do
        link(account_id: '')
        follow_redirect!
        expect(page.at_css('.flashes').text).to include('Выберите аккаунт из списка.')

        link(account_id: 0)
        follow_redirect!
        expect(page.at_css('.flashes').text).to include('Выберите аккаунт из списка.')
        expect(organization.accounts.count).to eq(0)
      end
    end

    describe 'unlinking an account' do
      let!(:organization) { create(:organization, name: 'Алатау') }
      let!(:account) { create(:account, name: 'Филиал 1', organization: organization) }

      def unlink(target = organization, account_id: account.id)
        delete "/super_admin/organizations/#{target.id}/unlink_account", params: { account_id: account_id }
      end

      it 'unlinks the account, keeps the account and says so' do
        unlink

        expect(response).to redirect_to("/super_admin/organizations/#{organization.id}")
        expect(account.reload.organization).to be_nil
        expect(Account.exists?(account.id)).to be(true)
        follow_redirect!
        expect(page.at_css('.flashes').text).to include('Аккаунт «Филиал 1» отвязан от организации.')
        expect(page.css('[data-testid="accounts-block"] tbody tr[data-account-id]')).to be_empty
      end

      it 'records the unlinking on both sides' do
        unlink

        account_audit = audits_of(account, 'unlink_organization').sole
        expect(account_audit.user).to eq(super_admin)
        expect(account_audit.audited_changes).to eq('organization_id' => [organization.id, nil], 'organization_name' => ['Алатау', nil])
        organization_audit = audits_of(organization, 'unlink_account').sole
        expect(organization_audit.audited_changes).to eq('account_id' => account.id, 'account_name' => 'Филиал 1')
      end

      it 'frees the account for another organization, and deleting the organization then works' do
        unlink
        other = create(:organization)

        post "/super_admin/organizations/#{other.id}/link_account", params: { account_id: account.id }
        delete "/super_admin/organizations/#{organization.id}"

        expect(account.reload.organization).to eq(other)
        expect(Organization.exists?(organization.id)).to be(false)
      end

      it 'does not unlink an account of another organization' do
        other = create(:organization)
        foreign = create(:account, organization: other)

        unlink(account_id: foreign.id)

        follow_redirect!
        expect(page.at_css('.flashes').text).to include('Этот аккаунт не привязан к организации.')
        expect(foreign.reload.organization).to eq(other)
        expect(audits_of(foreign)).to be_empty
      end

      # The card was drawn with the account in its table; `stale` is the account as that page saw it
      def serve_stale(stale)
        allow(Account).to receive(:find_by).and_call_original
        allow(Account).to receive(:find_by).with(id: stale.id.to_s).and_return(stale)
      end

      it 'does not unlink an account that was moved to another organization after the page was drawn' do
        other = create(:organization, name: 'Нур')
        stale = Account.find(account.id)
        account.update_columns(organization_id: other.id) # rubocop:disable Rails/SkipsModelValidations
        serve_stale(stale)

        unlink

        follow_redirect!
        expect(page.at_css('.flashes').text).to include('Этот аккаунт не привязан к организации.')
        expect(account.reload.organization).to eq(other)
        expect(audits_of(account)).to be_empty
        expect(audits_of(organization, 'unlink_account')).to be_empty
        expect(audits_of(other, 'unlink_account')).to be_empty
      end

      it 'does not unlink twice an account that another super admin unlinked after the page was drawn' do
        stale = Account.find(account.id)
        account.update_columns(organization_id: nil) # rubocop:disable Rails/SkipsModelValidations
        serve_stale(stale)

        unlink

        follow_redirect!
        expect(page.at_css('.flashes').text).to include('Этот аккаунт не привязан к организации.')
        expect(Audited::Audit.where(action: %w[unlink_organization unlink_account])).to be_empty
      end

      it 'does not unlink an account that has no organization' do
        free = create(:account)

        unlink(account_id: free.id)

        follow_redirect!
        expect(page.at_css('.flashes').text).to include('Этот аккаунт не привязан к организации.')
      end
    end
  end
end
