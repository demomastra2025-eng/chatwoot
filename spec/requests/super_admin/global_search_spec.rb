# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Super admin search', type: :request do
  let(:super_admin) { create(:super_admin) }

  # Not memoized: some examples open several pages in a row.
  def page = Nokogiri::HTML(response.body)

  def group(key) = page.at_css("[data-testid='search-group-#{key}']")

  describe 'the box in the header' do
    before { sign_in(super_admin, scope: :super_admin) }

    it 'is on the pages of the console, in the sidebar, and sends the term to the results page' do
      [super_admin_root_path, super_admin_accounts_path, super_admin_channels_path, super_admin_audits_path].each do |path|
        get path

        form = page.at_css("nav form[data-testid='global-search']")
        expect(form).to be_present, "#{path} should have the search box"
        expect(form['action']).to eq('/super_admin/search')
        expect(form['method']).to eq('get')
        expect(form['role']).to eq('search')
        expect(form.at_css('input[type="search"][name="q"]')['placeholder']).to eq('Аккаунт, e-mail или БИН')
        expect(form.at_css('label.sr-only').text).to eq('Поиск по аккаунтам, пользователям и организациям')
      end
    end

    it 'keeps the term in the box on the results page' do
      get '/super_admin/search', params: { q: 'Алатау' }

      expect(page.at_css("nav form[data-testid='global-search'] input[name='q']")['value']).to eq('Алатау')
    end

    it 'is not a page of the sidebar of its own' do
      get '/super_admin/search', params: { q: 'алатау' }

      expect(page.css('nav a').map { |link| link['href'] }).not_to include('/super_admin/search')
    end
  end

  describe 'GET /super_admin/search' do
    it 'sends an unauthenticated visitor to the login' do
      get '/super_admin/search', params: { q: 'алатау' }

      expect(response).to redirect_to('/super_admin/sign_in')
    end

    it 'does not let a clinic administrator in' do
      account = create(:account)
      sign_in(create(:user, account: account, role: :administrator))

      get '/super_admin/search', params: { q: 'алатау' }

      expect(response).to have_http_status(:redirect)
      expect(response.body).not_to include(account.name)
    end

    context 'with a super admin' do
      let!(:alatau) { create(:account, name: 'Клиника «Алатау»') }
      let!(:organization) { create(:organization, :with_requisites, name: 'Алатау Медикал') }
      let!(:ivan) { create(:user, email: 'ivan@example.test', name: 'Иван Алатауов', account: alatau) }

      before { sign_in(super_admin, scope: :super_admin) }

      it 'groups the results: accounts, users and organizations, each linked to its card' do
        get '/super_admin/search', params: { q: 'АЛАТАУ' }

        expect(response).to have_http_status(:success)
        expect(page.at_css('main h1').text.squish).to eq('Поиск')
        expect(page.at_css('main .main-content__description').text.squish).to eq('Результаты по запросу «АЛАТАУ»')
        expect(page.css('[data-testid^="search-group-"]').map { |node| node.at_css('h2').text.squish }).to eq(%w[Аккаунты Пользователи Организации])
        expect(group(:accounts).at_css('a')['href']).to eq("/super_admin/accounts/#{alatau.id}")
        expect(group(:accounts).text).to include('Клиника «Алатау»', "##{alatau.id}")
        expect(group(:users).at_css('a')['href']).to eq("/super_admin/users/#{ivan.id}")
        expect(group(:users).text).to include('ivan@example.test', 'Иван Алатауов', 'в 1 аккаунте')
        expect(group(:organizations).at_css('a')['href']).to eq("/super_admin/organizations/#{organization.id}")
        expect(group(:organizations).text).to include('Алатау Медикал', "БИН #{organization.bin}")
      end

      it 'finds an organization by the БИН' do
        get '/super_admin/search', params: { q: organization.bin }

        expect(group(:organizations).text).to include('Алатау Медикал')
        expect(group(:accounts).text).to include('Совпадений нет')
      end

      it 'shows ten of a group and links to the filtered list for the rest' do
        create_list(:account, 12) { |account, index| account.update!(name: "Сезим #{index}") }

        get '/super_admin/search', params: { q: 'сезим' }

        expect(group(:accounts).css('tbody tr').size).to eq(10)
        expect(group(:accounts)['data-total']).to eq('12')
        all_link = group(:accounts).at_css("[data-testid='search-all-accounts']")
        expect(all_link.text.squish).to eq('Показать все (12)')
        expect(all_link['href']).to eq('/super_admin/accounts?search=%D1%81%D0%B5%D0%B7%D0%B8%D0%BC')
        expect(group(:users).at_css("[data-testid='search-all-users']")).to be_nil
      end

      it 'says that nothing was found' do
        get '/super_admin/search', params: { q: 'нет такого' }

        expect(page.at_css("[data-testid='search-nothing']").text).to include('По запросу «нет такого» ничего не найдено')
        expect(page.at_css('[data-testid^="search-group-"]')).to be_nil
      end

      it 'asks for a term when the box was empty, and for two characters when there is one' do
        get '/super_admin/search'
        expect(page.at_css("[data-testid='search-hint']").text).to include('Введите название или номер аккаунта')

        get '/super_admin/search', params: { q: 'а' }
        expect(page.at_css("[data-testid='search-hint']").text).to include('не меньше двух символов')
      end

      it 'shows the term as text, never as markup' do
        get '/super_admin/search', params: { q: '<script>alert(1)</script>' }

        expect(response.body).not_to include('<script>alert(1)</script>')
        expect(response.body).to include('&lt;script&gt;alert(1)&lt;/script&gt;')
      end

      it 'does not fail on a term that is not text' do
        get '/super_admin/search', params: { q: { a: 'b' } }

        expect(response).to have_http_status(:success)
        expect(page.at_css("[data-testid='search-hint']")).to be_present
      end

      it 'costs the same number of queries for one match and for many' do
        alatau.update!(organization: organization) # the organizations of the accounts are read with one query, so one has one
        get '/super_admin/search', params: { q: 'алатау' }
        few = sql_queries_during { get '/super_admin/search', params: { q: 'алатау' } }
        12.times do |index|
          account = create(:account, name: "Алатау филиал #{index}", organization: organization)
          create(:user, email: "alatau#{index}@example.test", name: "Алатау #{index}", account: account)
        end
        many = sql_queries_during { get '/super_admin/search', params: { q: 'алатау' } }

        expect(many.size).to eq(few.size), "few:
#{few.join("
")}
many:
#{many.join("
")}"
      end
    end
  end
end
