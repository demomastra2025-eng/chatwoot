require 'rails_helper'

RSpec.describe 'Super Admin Dashboard', type: :request do
  let(:super_admin) { create(:super_admin) }

  describe 'GET /super_admin' do
    context 'when it is an unauthenticated super admin' do
      it 'returns unauthorized' do
        get '/super_admin/'
        expect(response).to have_http_status(:redirect)
      end
    end

    context 'when it is an authenticated super admin' do
      it 'renders the dashboard navigation without helper errors' do
        sign_in(super_admin, scope: :super_admin)

        get '/super_admin/'

        expect(response).to have_http_status(:success)
        expect(response.body).to include('Супер-админка')
        expect(response.body).not_to include('Super Admin Console')
        expect(response.body).to include('Dashboard')
        expect(response.body).to include('Кабинет оператора')
        expect(response.body).to include('href="/app"')
      end

      it 'does not render a hard-coded DEV badge or release SHA' do
        sign_in(super_admin, scope: :super_admin)

        get '/super_admin/'

        expect(response).to have_http_status(:success)
        expect(response.body).not_to include('93611c27')
        expect(response.body).not_to match(/>\s*DEV\s*</)
        expect(response.body).to include('data-testid="environment-badge"')
        expect(response.body).to include("#{Rails.env.upcase}</span>")
      end

      describe 'the «Сводка» page' do
        let(:page) { Nokogiri::HTML(response.body) }

        before do
          sign_in(super_admin, scope: :super_admin)
          create(:account, name: 'Аккаунт «Сезим»')
        end

        it 'is titled «Сводка», with no English name of the page' do
          get '/super_admin'

          expect(page.at_css('main h1').text.squish).to eq('Сводка')
          expect(page.at_css('title').text.squish).to eq('Сводка - OneLink Admin')
          expect(response.body).not_to match(/Health Matrix|Матрица здоровья/)
        end

        it 'shows the time of the data in Astana time and a button that asks for fresh data' do
          get '/super_admin'

          actions = page.at_css('main .main-content__actions')
          expect(actions.text).to match(/Обновлено: \d\d:\d\d:\d\d \(Астана\)/)
          expect(actions.at_css('a.button')['href']).to eq('/super_admin?refresh=true')
        end

        it 'hands the Vue body the clinics, the totals and the chart, and nothing it does not read' do
          get '/super_admin'

          props = JSON.parse(page.at_css('#app')['data-props'])
          expect(props.keys).to contain_exactly('chartData', 'healthAccounts', 'healthSummary')
          expect(props['healthAccounts'].pluck('name')).to include('Аккаунт «Сезим»')
          expect(props['healthSummary']).to include('total_accounts', 'needs_attention', 'updated_at')
        end

        it 'asks the health service for fresh data on a refresh' do
          allow(SuperAdmin::HealthMatrixService).to receive(:build).and_call_original

          get '/super_admin', params: { refresh: true }

          expect(SuperAdmin::HealthMatrixService).to have_received(:build).with(force_refresh: true)
        end

        it 'hands the chart the conversations of the summary' do
          create(:conversation, created_at: 3.days.ago)

          get '/super_admin'

          chart = JSON.parse(page.at_css('#app')['data-props'])['chartData']
          expect(chart.size).to be_between(30, 31)
          expect(chart.sum(&:last)).to eq(1)
        end
      end

      describe 'the headline tiles' do
        let(:page) { Nokogiri::HTML(response.body) }

        def tiles = page.css("[data-testid='dashboard-tiles'] [data-testid='stat']")

        def tile(label) = tiles.find { |figure| figure.at_css('dt').text.squish == label }

        def value_of(label) = tile(label).css('dd').first.text.squish

        def note_of(label) = tile(label).css('dd').last.text.squish

        before do
          allow(Llm::OpenRouterKeyHealth).to receive(:metadata).and_return({ status: 'valid' })
          allow(SuperAdmin::QueueStats).to receive(:read)
            .and_return(SuperAdmin::QueueStats::Result.new(busy: 0, enqueued: 0, scheduled: 0, retries: 0, dead: 0, processed: 0, failed: 0, queues: []))
          sign_in(super_admin, scope: :super_admin)
        end

        it 'shows six figures, each with a line of what it means' do
          get '/super_admin'

          expect(tiles.map { |figure| figure.at_css('dt').text.squish }).to eq(
            ['Активные аккаунты', 'На пробном периоде', 'Требуют внимания', 'Новые за 30 дней', 'Сообщений за сутки', 'Заблокированы']
          )
          expect(tiles.map { |figure| figure.css('dd').last.text.squish }).to all(be_present)
        end

        it 'counts the accounts and the messages' do
          create(:account, name: 'Первый')
          create(:account, name: 'Блокированный', status: :suspended)
          create(:account, name: 'Старый', created_at: 60.days.ago)
          create(:account, name: 'На пробе', custom_attributes: { 'plan_type' => 'trial', 'trial_expires_at' => 10.days.from_now.iso8601 })
          create(:message, message_type: :incoming)

          get '/super_admin'

          expect(value_of('Активные аккаунты').to_i).to be >= 3
          expect(value_of('Заблокированы')).to eq('1')
          expect(value_of('На пробном периоде')).to eq('1')
          expect(note_of('На пробном периоде')).to eq('за 3 дня не заканчивается ни один')
          expect(value_of('Сообщений за сутки')).to eq('1')
        end

        it 'says how many trials end in the next three days' do
          create(:account, custom_attributes: { 'plan_type' => 'trial', 'trial_expires_at' => 1.day.from_now.iso8601 })
          create(:account, custom_attributes: { 'plan_type' => 'trial', 'trial_expires_at' => 9.days.from_now.iso8601 })

          get '/super_admin'

          expect(value_of('На пробном периоде')).to eq('2')
          expect(note_of('На пробном периоде')).to eq('заканчивается за 3 дня: 1')
        end

        it 'opens the list of accounts with the filter the figure was counted by' do
          get '/super_admin'

          links = ['Активные аккаунты', 'На пробном периоде', 'Новые за 30 дней', 'Заблокированы'].map { |label| tile(label).at_css('a')['href'] }
          expect(links).to eq(%w[active trial_active recent suspended].map { |filter| "/super_admin/accounts?search=#{filter}%3A" })
          expect(tile('Сообщений за сутки').at_css('a')).to be_nil
        end

        it 'counts the problems of the list below, leads to it and is red only when there are some' do
          get '/super_admin'
          expect(value_of('Требуют внимания')).to eq('0')
          expect(note_of('Требуют внимания')).to eq('всё в порядке')
          expect(tile('Требуют внимания').at_css('dd')['class']).not_to include('text-n-ruby-11')

          create(:account, custom_attributes: { 'plan_type' => 'trial', 'trial_expires_at' => 1.day.from_now.iso8601 })
          get '/super_admin'

          expect(value_of('Требуют внимания')).to eq('1')
          expect(note_of('Требуют внимания')).to eq('проблем в списке ниже')
          expect(tile('Требуют внимания').at_css('dd')['class']).to include('text-n-ruby-11')
          expect(tile('Требуют внимания').at_css('a')['href']).to eq('#dashboard-checklist')
          expect(page.at_css('#dashboard-checklist-title')).to be_present
        end

        it 'says «нет данных», not 0, for a figure that could not be counted' do
          allow(Message).to receive(:unscoped).and_raise(ActiveRecord::StatementInvalid, 'canceling statement due to statement timeout')

          get '/super_admin'

          expect(response).to have_http_status(:success)
          expect(value_of('Сообщений за сутки')).to eq('—')
          expect(note_of('Сообщений за сутки')).to eq('нет данных')
          expect(value_of('Заблокированы')).to eq('0')
        end
      end
    end
  end
end
