# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Super admin «Сводка»: Нужно проверить', type: :request do
  let(:super_admin) { create(:super_admin) }

  # Not memoized: some examples open several pages in a row.
  def page = Nokogiri::HTML(response.body)

  def queue_stats(dead: 0, queues: [])
    SuperAdmin::QueueStats::Result.new(busy: 0, enqueued: 0, scheduled: 0, retries: 0, dead: dead, processed: 0, failed: 0, queues: queues)
  end

  before do
    allow(Llm::OpenRouterKeyHealth).to receive(:metadata).and_return({ status: 'valid' })
    allow(SuperAdmin::QueueStats).to receive(:read).and_return(queue_stats)
    sign_in(super_admin, scope: :super_admin)
  end

  it 'says that all is well when nothing needs attention' do
    get '/super_admin'

    expect(page.at_css("[data-testid='dashboard-alerts-clear']").text.squish).to start_with('Всё в порядке')
    expect(page.at_css("[data-testid='dashboard-alerts']")).to be_nil
  end

  it 'lists what needs attention above the body of the page, the serious first, each with a link' do
    ending = create(:account, name: 'Клиника «Алатау»', custom_attributes: { 'plan_type' => 'trial', 'trial_expires_at' => 2.days.from_now.iso8601 })
    allow(SuperAdmin::QueueStats).to receive(:read)
      .and_return(queue_stats(queues: [SuperAdmin::QueueStats::Queue.new(name: 'default', jobs: 7, latency: 180)]))

    get '/super_admin'

    block = page.at_css("[data-testid='dashboard-alerts']")
    expect(block.at_css('h2').text.squish).to eq('Нужно проверить')
    cards = block.css('[data-alert]')
    expect(cards.map { |card| card['data-alert'] }).to eq(%w[queues_slow trials_ending])
    expect(cards.map { |card| card['data-severity'] }).to eq(%w[danger warning])
    expect(cards.first['role']).to eq('alert')
    expect(cards.first.at_css('a')['href']).to eq('/super_admin/monitoring?tab=queues')
    expect(cards.last.at_css('a')['href']).to eq("/super_admin/accounts/#{ending.id}")
    expect(cards.last.at_css('h3').text.squish).to eq('Пробный период заканчивается в ближайшие 3 дня')
  end

  it 'does not say that all is well when the checks could not be made' do
    allow(Rails.cache).to receive(:fetch).and_call_original
    allow(Rails.cache).to receive(:fetch).with(SuperAdmin::DashboardAlerts::CACHE_KEY, any_args).and_raise(StandardError, 'cache down')

    get '/super_admin'

    expect(response).to have_http_status(:success)
    expect(page.at_css("[data-testid='dashboard-alerts-clear']")).to be_nil
    expect(page.at_css("[data-alert='incomplete']").text.squish).to include('Не удалось выполнить ни одну проверку')
  end

  it 'draws the block above the body of the page' do
    get '/super_admin'

    expect(response.body.index('data-testid="dashboard-alerts-clear"')).to be < response.body.index('id="app"')
  end

  it 'offers the whole list when there are more than ten' do
    create_list(:account, 12) do |account, index|
      account.update!(custom_attributes: { 'plan_type' => 'trial', 'trial_expires_at' => (index + 1).hours.from_now.iso8601 })
    end

    get '/super_admin'

    card = page.at_css("[data-alert='trials_ending']")
    expect(card.css('[data-alert-item]').size).to eq(10)
    expect(card.text.squish).to include('Найдено: 12', 'Показаны первые, ещё: 2')
    expect(card.css('a').last['href']).to eq('/super_admin/accounts?search=trial_active%3A')
    expect(card.css('a').last.text.squish).to eq('Все аккаунты на пробном периоде')
  end

  it 'says how many jobs are dead and does not promise a list of them: one link opens the queues' do
    allow(SuperAdmin::QueueStats).to receive(:read).and_return(queue_stats(dead: 4))

    get '/super_admin'

    card = page.at_css("[data-alert='queues_dead']")
    expect(card['data-severity']).to eq('warning')
    expect(card.text.squish).to include('Найдено: 4')
    expect(card.text.squish).not_to include('Показаны первые')
    expect(card.css('[data-alert-item]').size).to eq(1)
    expect(card.css('a').map { |link| link['href'] }).to eq(['/super_admin/monitoring?tab=queues'])
  end

  it 'lists a personal Telegram and a WhatsApp Web number that need a new login, with a link to the account' do
    account = create(:account, name: 'Клиника «Алатау»')
    create(:channel_telegram_personal, account: account, connection_state: 'auth_required').inbox.update!(name: 'Рабочий Telegram')
    create(:channel_whatsapp_web, account: account, lifecycle_state: 'disconnected').inbox.update!(name: 'Номер регистратуры')

    get '/super_admin'

    card = page.at_css("[data-alert='reauthorization']")
    expect(card['data-severity']).to eq('danger')
    expect(card.css('[data-alert-item]').map { |item| item.text.squish }).to contain_exactly(
      'Рабочий Telegram · Клиника «Алатау» Telegram (личный)', 'Номер регистратуры · Клиника «Алатау» WhatsApp Web'
    )
    expect(card.css('a').map { |link| link['href'] }.uniq).to eq(["/super_admin/accounts/#{account.id}"])
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
    expect(Llm::OpenRouterKeyHealth).not_to receive(:refresh!)

    get '/super_admin', params: { refresh: true }

    expect(SuperAdmin::DashboardAlerts).to have_received(:build).with(force_refresh: true)
  end

  it 'keeps the data of the Vue body as it was' do
    get '/super_admin'

    expect(JSON.parse(page.at_css('#app')['data-props']).keys).to contain_exactly('chartData', 'healthAccounts', 'healthSummary')
  end
end
