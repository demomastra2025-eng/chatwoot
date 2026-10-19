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
      end
    end
  end
end
