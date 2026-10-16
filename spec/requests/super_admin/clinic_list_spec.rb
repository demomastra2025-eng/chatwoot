require 'rails_helper'

RSpec.describe 'Super Admin clinic list', type: :request do
  let(:super_admin) { create(:super_admin) }
  let(:page) { Nokogiri::HTML(response.body) }

  before { sign_in(super_admin, scope: :super_admin) }

  def row_of(account)
    page.at_css("tr[data-account-id='#{account.id}']")
  end

  def cell(account, index)
    row_of(account).css('td')[index]
  end

  def text(node)
    node.text.squish
  end

  def storage_key(account)
    "account:#{account.id}:storage_overview_v1"
  end

  # Counts the SQL statements a block runs (cached reads and schema lookups do not count)
  def query_count(&)
    count = 0
    counter = ->(*, payload) { count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) || payload[:cached] }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &)
    count
  end

  describe 'the page' do
    it 'is titled «Аккаунты», explains itself and offers a new clinic and the export' do
      get '/super_admin/accounts'

      expect(response).to have_http_status(:ok)
      expect(text(page.at_css('h1.main-content__page-title'))).to eq('Аккаунты')
      expect(text(page.at_css('.main-content__description'))).to include('Все аккаунты платформы')
      expect(text(page.at_css('a[href="/super_admin/accounts/new"]'))).to eq('Новый аккаунт')
      expect(text(page.at_css('a[href="/super_admin/accounts/export"]'))).to eq('Экспорт в CSV')
      expect(page.at_css('title').text).to include('Аккаунты')
    end

    it 'has the columns of the clinic table' do
      get '/super_admin/accounts'

      headers = page.css('[data-testid="clinics-table"] thead th').map { |header| text(header) }
      expect(headers).to eq(%w[Аккаунт Тариф Операторы Хранилище Каналы Статус Действия])
    end

    it 'shows an empty state when nothing matches' do
      get '/super_admin/accounts', params: { search: 'no-clinic-has-this-name' }

      expect(response.body).to include('Ничего не найдено')
    end

    it 'does not show English leftovers' do
      create(:account)

      get '/super_admin/accounts'

      expect(response.body).not_to match(/Unlimited|Suspended/)
    end
  end

  describe 'the clinic cell' do
    it 'links the name to the card and shows #id' do
      account = create(:account, name: 'Аккаунт Алатау')

      get '/super_admin/accounts'

      link = cell(account, 0).at_css('a')
      expect(link['href']).to eq("/super_admin/accounts/#{account.id}")
      expect(text(link)).to eq('Аккаунт Алатау')
      expect(text(cell(account, 0))).to include("##{account.id}")
      expect(row_of(account)['data-url']).to eq("/super_admin/accounts/#{account.id}")
    end
  end

  describe 'the plan cell' do
    it 'shows «Не назначен» for a clinic without a plan' do
      account = create(:account)

      get '/super_admin/accounts'

      expect(text(cell(account, 1))).to eq('Не назначен')
    end

    it 'shows the base and the modules as chips' do
      account = create(:account)
      Accounts::ApplyPlan.new(account: account, modules: %w[ai_agents broadcasts]).call

      get '/super_admin/accounts'

      chips = cell(account, 1).css('.admin-badge').map { |chip| text(chip) }
      expect(chips).to eq(%w[База ИИ-агенты Рассылки])
      expect(text(cell(account, 1))).not_to include('изменён')
    end

    it 'marks a clinic whose functions were changed by hand' do
      account = create(:account)
      Accounts::ApplyPlan.new(account: account, modules: []).call
      account.enable_features!('sla')

      get '/super_admin/accounts'

      expect(text(cell(account, 1))).to include('изменён')
    end

    it 'shows the remaining days of a running trial' do
      account = create(:account)
      account.activate_trial!(3)

      get '/super_admin/accounts'

      expect(text(cell(account, 1))).to eq('Пробный · осталось 3 дн.')
    end

    it 'shows an ended trial' do
      account = create(:account)
      account.activate_trial!(3)
      account.expire_trial!

      get '/super_admin/accounts'

      expect(text(cell(account, 1))).to eq('Пробный истёк')
    end
  end

  describe 'the operators cell' do
    it 'shows used and the limit' do
      account = create(:account, limits: { 'agents' => 10 })
      create_list(:user, 2, account: account)

      get '/super_admin/accounts'

      expect(text(cell(account, 2))).to eq('2 / 10')
    end

    it 'says «без лимита» when the clinic has none' do
      account = create(:account)
      create(:user, account: account)
      GlobalConfig.clear_cache

      get '/super_admin/accounts'

      expect(text(cell(account, 2))).to eq('1 без лимита')
    end

    it 'says «без лимита» for the no-limit value a plan writes (the maximum limit)' do
      account = create(:account, limits: { 'agents' => ChatwootApp.max_limit })
      create(:user, account: account)

      get '/super_admin/accounts'

      expect(text(cell(account, 2))).to eq('1 без лимита')
    end

    it 'turns red when there are more operators than the limit' do
      account = create(:account, limits: { 'agents' => 1 })
      create_list(:user, 2, account: account)

      get '/super_admin/accounts'

      expect(cell(account, 2).at_css('.text-n-ruby-11')).to be_present
    end
  end

  describe 'the storage cell' do
    let!(:account) { create(:account) }

    after { Redis::Alfred.delete(storage_key(account)) }

    it 'shows a meter and the size from the hourly snapshot' do
      limits = { total_count: 50.gigabytes, consumed: 40.gigabytes, current_available: 10.gigabytes, unlimited: false }
      Redis::Alfred.set(storage_key(account), JSON.generate(limits: limits))

      get '/super_admin/accounts'

      expect(text(cell(account, 3))).to eq('40 ГБ из 50 ГБ')
      fill = cell(account, 3).at_css('.admin-meter__fill')
      expect(fill['style']).to include('width: 80.0%')
      expect(fill['class']).to include('admin-meter__fill--warn')
    end

    it 'shows a dash while there is no snapshot' do
      get '/super_admin/accounts'

      expect(text(cell(account, 3))).to eq('—')
    end
  end

  describe 'the channels and status cells' do
    it 'counts the channels' do
      account = create(:account)
      create_list(:inbox, 3, account: account)

      get '/super_admin/accounts'

      expect(text(cell(account, 4))).to eq('3')
    end

    it 'shows the status in Russian' do
      active = create(:account)
      suspended = create(:account, status: :suspended)
      deleting = create(:account, custom_attributes: { 'marked_for_deletion_at' => 3.days.from_now.iso8601 })

      get '/super_admin/accounts'

      expect(text(cell(active, 5))).to eq('Активен')
      expect(text(cell(suspended, 5))).to eq('Заблокирован')
      expect(text(cell(deleting, 5))).to eq('На удаление')
    end

    it 'offers «Редактировать» in the last cell' do
      account = create(:account)

      get '/super_admin/accounts'

      expect(cell(account, 6).at_css('a')['href']).to eq("/super_admin/accounts/#{account.id}/edit")
    end
  end

  describe 'the filters' do
    it 'are the segmented control in the order of the list, in Russian' do
      get '/super_admin/accounts'

      labels = page.css('.segmented .segmented__item').map { |item| text(item) }
      expect(labels).to eq(
        ['Все', 'Активные', 'Заблокированные', 'Пробные', 'Истёкший пробный', 'Без тарифа', 'База', 'Модуль: ИИ-агенты', 'Модуль: Рассылки',
         'Модуль: Контроль качества', 'Модуль: Расширения', 'Новые за 30 дней', 'Диск > 80%', 'На удаление']
      )
    end

    it 'say in a tooltip that «Диск > 80%» counts chat attachments only, while the list meter counts recordings too' do
      get '/super_admin/accounts'

      titled = page.css('.segmented .segmented__item[title]')
      expect(titled.map { |item| text(item) }).to eq(['Диск > 80%'])
      expect(titled.first['title']).to include('записи звонков в этот фильтр не входят')
    end

    it 'show the trial clinics' do
      trial = create(:account, name: 'Trial clinic')
      trial.activate_trial!(3)
      create(:account, name: 'Plain clinic')

      get '/super_admin/accounts', params: { search: 'trial_active:' }

      expect(response.body).to include('Trial clinic')
      expect(response.body).not_to include('Plain clinic')
      expect(text(page.at_css('.segmented [aria-current="true"]'))).to eq('Пробные')
    end

    it 'show the clinics of a module' do
      with_module = create(:account, name: 'With broadcasts')
      Accounts::ApplyPlan.new(account: with_module, modules: %w[broadcasts]).call
      create(:account, name: 'Without module')

      get '/super_admin/accounts', params: { search: 'module_broadcasts:' }

      expect(response.body).to include('With broadcasts')
      expect(response.body).not_to include('Without module')
    end
  end

  describe 'queries' do
    it 'cost the same for 2 clinics and for 12' do
      accounts = create_list(:account, 2)
      accounts.each do |account|
        create_list(:inbox, 2, account: account)
        create(:user, account: account)
        Accounts::ApplyPlan.new(account: account, modules: %w[ai_agents]).call
      end
      get '/super_admin/accounts' # warms the caches the first request fills

      small = query_count { get '/super_admin/accounts' }
      expect(Nokogiri::HTML(response.body).css('tr[data-account-id]').size).to eq(2)

      more = create_list(:account, 10)
      more.each do |account|
        create_list(:inbox, 2, account: account)
        create(:user, account: account)
        account.activate_trial!(3)
      end
      large = query_count { get '/super_admin/accounts' }

      expect(Nokogiri::HTML(response.body).css('tr[data-account-id]').size).to eq(12)
      expect(large).to eq(small)
    end
  end
end
