# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Super admin «Сводка»: Нужно проверить', type: :request do
  let(:super_admin) { create(:super_admin) }

  # Not memoized: some examples open several pages in a row.
  def page = Nokogiri::HTML(response.body)

  def queue_stats(dead: 0, queues: [])
    SuperAdmin::QueueStats::Result.new(busy: 0, enqueued: 0, scheduled: 0, retries: 0, dead: dead, processed: 0, failed: 0, queues: queues)
  end

  def list = page.at_css("[data-testid='dashboard-checklist']")

  def rows = list.css('[data-checklist-row]:not([data-more])')

  def row_keys = rows.pluck('data-checklist-row')

  # An account as the table of the page gets it from SuperAdmin::HealthMatrixService
  def table_account(id, name, **lines)
    {
      id: id, name: name, status: 'active', whatsapp: { state: 'none', label: 'Не подключен' }, telephony: { state: 'none', label: 'Нет линий' },
      medelement: { state: 'none', label: 'Не настроен' }, failed_messages: 0, needs_attention: false
    }.merge(lines)
  end

  def stub_table(accounts, incomplete: [])
    summary = { total_accounts: accounts.size, incomplete_sources: incomplete, updated_at: '12:00:00' }
    allow(SuperAdmin::HealthMatrixService).to receive(:build).and_return([accounts, summary])
  end

  before do
    allow(Llm::OpenRouterKeyHealth).to receive(:metadata).and_return({ status: 'valid' })
    allow(SuperAdmin::QueueStats).to receive(:read).and_return(queue_stats)
    sign_in(super_admin, scope: :super_admin)
  end

  it 'says «Всё в порядке» when nothing needs attention, and says what was checked' do
    get '/super_admin'

    expect(list.at_css('h2').text.squish).to eq('Нужно проверить')
    expect(list.at_css("[data-testid='dashboard-checklist-clear']").text.squish).to start_with('Всё в порядке')
    expect(list.at_css("[data-testid='dashboard-checklist-clear']").text).to include('пробные периоды', 'телефония', 'МедЭлемент')
    expect(list.at_css("[data-testid='dashboard-checklist-rows']")).to be_nil
    expect(list.at_css("[data-testid='dashboard-checklist-count']")).to be_nil
    expect(list['data-severity']).to eq('clear')
  end

  describe 'a list with a problem of the platform and a problem of an account' do
    let!(:ending) do
      create(:account, name: 'Клиника «Алатау»', custom_attributes: { 'plan_type' => 'trial', 'trial_expires_at' => 2.days.from_now.iso8601 })
    end
    let(:slow_queue) { SuperAdmin::QueueStats::Queue.new(name: 'default', jobs: 7, latency: 180) }

    before do
      allow(SuperAdmin::QueueStats).to receive(:read).and_return(queue_stats(queues: [slow_queue]))
      get '/super_admin'
    end

    def text_of(row, testid) = row.at_css("[data-testid='#{testid}']").text.squish

    it 'puts the serious first and says how serious each is with a word, not with a colour alone' do
      expect(row_keys).to eq(%w[queues_slow trials_ending])
      expect(rows.pluck('data-severity')).to eq(%w[danger warning])
      expect(rows.map { |row| text_of(row, 'row-severity') }).to eq(%w[Срочно Важно])
    end

    it 'gives a problem of the platform one button to the place where it is put right' do
      row = rows.first

      expect(text_of(row, 'row-title')).to eq('Фоновые задачи отстают')
      expect(text_of(row, 'row-subject')).to eq('Вся платформа')
      expect(row.css("[data-testid='row-action']").map { |link| link['href'] }).to eq(['/super_admin/monitoring?tab=queues'])
    end

    it 'gives a problem of an account its name and one button to the block of the card where it is put right' do
      row = rows.last

      expect(text_of(row, 'row-title')).to eq('Пробный период заканчивается')
      expect(text_of(row, 'row-subject')).to eq('Клиника «Алатау»')
      expect(row.css('a').map { |link| link['href'] }).to eq(["/super_admin/accounts/#{ending.id}#trial-title"])
      expect(text_of(row, 'row-action')).to eq('Продлить или назначить тариф')
    end
  end

  it 'colours the badge by the most serious problem and counts the problems' do
    create(:account, custom_attributes: { 'plan_type' => 'trial', 'trial_expires_at' => 2.days.from_now.iso8601 })

    get '/super_admin'
    expect(list.at_css("[data-testid='dashboard-checklist-count']")['class']).to include('admin-badge--amber')
    expect(list.at_css("[data-testid='dashboard-checklist-count']").text.squish).to eq('1')

    allow(SuperAdmin::QueueStats).to receive(:read)
      .and_return(queue_stats(queues: [SuperAdmin::QueueStats::Queue.new(name: 'default', jobs: 7, latency: 180)]))
    get '/super_admin'
    expect(list.at_css("[data-testid='dashboard-checklist-count']")['class']).to include('admin-badge--ruby')
    expect(list.at_css("[data-testid='dashboard-checklist-count']").text.squish).to eq('2')
  end

  it 'does not say that all is well when the checks could not be made' do
    allow(Rails.cache).to receive(:fetch).and_call_original
    allow(Rails.cache).to receive(:fetch).with(SuperAdmin::DashboardAlerts::CACHE_KEY, any_args).and_raise(StandardError, 'cache down')

    get '/super_admin'

    expect(response).to have_http_status(:success)
    expect(list.at_css("[data-testid='dashboard-checklist-clear']")).to be_nil
    expect(row_keys).to eq(['incomplete'])
    expect(rows.first.at_css("[data-testid='row-hint']").text.squish).to include('Не удалось выполнить ни одну проверку')
    expect(rows.first.at_css("[data-testid='row-action']")['href']).to eq('/super_admin?refresh=true')
  end

  it 'does not say that all is well when the table of the accounts could not be read' do
    allow(SuperAdmin::HealthMatrixService).to receive(:build).and_return([[], {}])

    get '/super_admin'

    expect(list.at_css("[data-testid='dashboard-checklist-clear']")).to be_nil
    expect(rows.first.at_css("[data-testid='row-title']").text.squish).to eq('Состояние аккаунтов не прочиталось')
  end

  it 'draws the list above the body of the page' do
    get '/super_admin'

    expect(response.body.index('data-testid="dashboard-checklist"')).to be < response.body.index('id="app"')
  end

  it 'draws the tiles above the list' do
    get '/super_admin'

    expect(response.body.index('data-testid="dashboard-tiles"')).to be < response.body.index('data-testid="dashboard-checklist"')
  end

  it 'shows the first rows and folds the rest under «Показать ещё», with the link to the whole list' do
    create_list(:account, 12) do |account, index|
      account.update!(custom_attributes: { 'plan_type' => 'trial', 'trial_expires_at' => (index + 1).hours.from_now.iso8601 })
    end

    get '/super_admin'

    expect(rows.size).to eq(10)
    expect(list.css("[data-testid='dashboard-checklist-rows'] > li").size).to eq(8)
    rest = list.at_css("[data-testid='dashboard-checklist-rest']")
    expect(rest.at_css('summary').text.squish).to eq('Показать ещё 3')
    expect(rest.css('li').size).to eq(3)
  end

  it 'closes the rows of a kind with the link to the whole list when only the first ten are listed' do
    create_list(:account, 12) do |account, index|
      account.update!(custom_attributes: { 'plan_type' => 'trial', 'trial_expires_at' => (index + 1).hours.from_now.iso8601 })
    end

    get '/super_admin'

    closing = list.at_css('[data-more]')
    expect(closing.text.squish).to include('Показаны первые 10 из 12.')
    expect(closing.at_css('a')['href']).to eq('/super_admin/accounts?search=trial_active%3A')
    expect(closing.at_css('a').text.squish).to eq('Все аккаунты на пробном периоде')
  end

  it 'has no fold when the list is short' do
    create(:account, custom_attributes: { 'plan_type' => 'trial', 'trial_expires_at' => 2.days.from_now.iso8601 })

    get '/super_admin'

    expect(list.at_css("[data-testid='dashboard-checklist-rest']")).to be_nil
  end

  it 'says how many jobs are dead and does not promise a list of them: one button opens the queues' do
    allow(SuperAdmin::QueueStats).to receive(:read).and_return(queue_stats(dead: 4))

    get '/super_admin'

    row = rows.first
    expect(row['data-checklist-row']).to eq('queues_dead')
    expect(row['data-severity']).to eq('warning')
    expect(row.at_css("[data-testid='row-title']").text.squish).to eq('Часть фоновых задач не выполнилась: 4')
    expect(row.css('a').map { |link| link['href'] }).to eq(['/super_admin/monitoring?tab=queues'])
    expect(row.at_css("[data-testid='row-action']").text.squish).to eq('Открыть очереди')
  end

  it 'folds the names of the slow queues under «Для разработчика»' do
    allow(SuperAdmin::QueueStats).to receive(:read)
      .and_return(queue_stats(queues: [SuperAdmin::QueueStats::Queue.new(name: 'default', jobs: 7, latency: 180)]))

    get '/super_admin'

    developer = rows.first.at_css("[data-testid='row-developer']")
    expect(developer.at_css('summary').text.squish).to eq('Для разработчика')
    expect(developer.text.squish).to include('default: ждёт 3 минуты, задач в очереди: 7')
    expect(rows.first.at_css("[data-testid='row-title']").text).not_to include('default')
  end

  it 'lists a personal Telegram and a WhatsApp Web number that need a new login, with a button to the account' do
    account = create(:account, name: 'Клиника «Алатау»')
    create(:channel_telegram_personal, account: account, connection_state: 'auth_required').inbox.update!(name: 'Рабочий Telegram')
    create(:channel_whatsapp_web, account: account, lifecycle_state: 'disconnected').inbox.update!(name: 'Номер регистратуры')

    get '/super_admin'

    expect(row_keys).to eq(%w[reauthorization reauthorization])
    expect(rows.map { |row| row.at_css("[data-testid='row-subject']").text.squish }).to contain_exactly(
      'Рабочий Telegram · Клиника «Алатау»', 'Номер регистратуры · Клиника «Алатау»'
    )
    expect(rows.map { |row| row.at_css("[data-testid='row-note']").text.squish }).to contain_exactly('Telegram (личный)', 'WhatsApp Web')
    expect(rows.pluck('data-severity').uniq).to eq(['danger'])
    expect(rows.flat_map { |row| row.css('a').pluck('href') }.uniq).to eq(["/super_admin/accounts/#{account.id}"])
  end

  it 'lists the problems of the table of accounts in the same list, with a button to the account' do
    stub_table([table_account(11, 'Клиника «Звонки»', telephony: { state: 'error', label: 'Сервер звонков не настроен' }),
                table_account(12, 'Клиника «Письма»', failed_messages: 6)])

    get '/super_admin'

    expect(row_keys).to eq(%w[telephony_error failed_messages])
    telephony, failed = rows.to_a
    expect(telephony.at_css("[data-testid='row-title']").text.squish).to eq('Телефония не настроена')
    expect(telephony.at_css("[data-testid='row-note']").text.squish).to eq('Сервер звонков не настроен')
    expect(telephony.at_css("[data-testid='row-action']")['href']).to eq('/super_admin/accounts/11')
    expect(failed.at_css("[data-testid='row-subject']").text.squish).to eq('Клиника «Письма»')
    expect(failed.at_css("[data-testid='row-note']").text.squish).to eq('за 3 дня: 6')
  end

  it 'names the parts of the table that could not be read in words' do
    stub_table([table_account(1, 'А')], incomplete: ['сообщения'])

    get '/super_admin'

    expect(row_keys).to eq(['matrix_incomplete'])
    expect(rows.first.at_css("[data-testid='row-hint']").text.squish).to include('Не удалось прочитать: сообщения.')
  end

  it 'writes the name of an account as text' do
    create(:account, name: '<img src=x onerror=alert(1)>',
                     custom_attributes: { 'plan_type' => 'trial', 'trial_expires_at' => 1.day.from_now.iso8601 })

    get '/super_admin'

    expect(response.body).not_to include('<img src=x onerror=alert(1)>')
    expect(response.body).to include('&lt;img src=x onerror=alert(1)&gt;')
  end

  it 'asks the checks for fresh data on a refresh, and does not ask OpenRouter on any visit' do
    allow(SuperAdmin::DashboardAlerts).to receive(:build).and_call_original
    allow(SuperAdmin::DashboardSummary).to receive(:build).and_call_original
    expect(Llm::OpenRouterKeyHealth).not_to receive(:refresh!)

    get '/super_admin', params: { refresh: true }

    expect(SuperAdmin::DashboardAlerts).to have_received(:build).with(force_refresh: true)
    expect(SuperAdmin::DashboardSummary).to have_received(:build).with(force_refresh: true)
  end

  it 'keeps the data of the Vue body as it was' do
    get '/super_admin'

    expect(JSON.parse(page.at_css('#app')['data-props']).keys).to contain_exactly('chartData', 'healthAccounts', 'healthSummary')
  end
end
