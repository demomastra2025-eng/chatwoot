require 'rails_helper'

RSpec.describe 'Super Admin Instance status', type: :request do
  let(:super_admin) { create(:super_admin) }

  describe 'GET /super_admin/instance_status' do
    context 'when it is an unauthenticated super admin' do
      it 'returns unauthorized' do
        get '/super_admin/instance_status'
        expect(response).to have_http_status(:redirect)
      end
    end

    context 'when it is an authenticated super admin' do
      before { sign_in(super_admin, scope: :super_admin) }

      it 'shows the instance_status page' do
        get '/super_admin/instance_status'
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('super_admin.instance_status.rows.version'))
        expect(response.body).to include(GIT_HASH)
      end

      it 'names the metrics in Russian and groups them in blocks' do
        get '/super_admin/instance_status'
        page = Nokogiri::HTML(response.body)

        expect(page.css('[data-testid^="status-"]').pluck('data-testid')).to eq(%w[status-platform status-postgres status-redis])
        labels = page.css('dt.attribute-label').map { |node| node.text.squish }
        expect(labels).to include('Редакция', 'Миграции базы данных', 'Подключение')
        expect(response.body).not_to match(/Redis alive|Postgres alive|Database Migrations|\btrue\b/)
      end

      it 'shows sizes in Russian units and no limit as «Без лимита»' do
        redis = instance_double(Redis, ping: 'PONG', info: {
                                  'redis_version' => '7.4.1', 'connected_clients' => '2', 'maxclients' => '10000',
                                  'used_memory' => 3.megabytes.to_s, 'used_memory_peak' => 5.megabytes.to_s,
                                  'total_system_memory' => 8.gigabytes.to_s, 'maxmemory' => '0',
                                  'maxmemory_policy' => 'noeviction'
                                })
        allow(Redis).to receive(:new).and_return(redis)

        get '/super_admin/instance_status'

        expect(response.body).to include('3 МБ', '5 МБ', '8 ГБ', 'Без лимита', 'noeviction')
        expect(response.body).not_to match(/\d[MG]\b/)
      end

      it 'says so when Redis does not answer' do
        allow(Redis).to receive(:new).and_raise(Redis::CannotConnectError)

        get '/super_admin/instance_status'

        expect(response).to have_http_status(:success)
        expect(response.body).to include('Нет связи')
      end
    end
  end
end
