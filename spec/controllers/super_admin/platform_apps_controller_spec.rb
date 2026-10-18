require 'rails_helper'

RSpec.describe 'Super Admin platform app API', type: :request do
  let(:super_admin) { create(:super_admin) }

  def page = Nokogiri::HTML(response.body)

  def main_text = page.at_css('main').text.squish

  describe 'GET /super_admin/platform_apps' do
    context 'when it is an unauthenticated super admin' do
      it 'returns unauthorized' do
        get '/super_admin/platform_apps'
        expect(response).to have_http_status(:redirect)
      end
    end

    context 'when it is an authenticated super admin' do
      let!(:platform_app) { create(:platform_app) }

      before { sign_in(super_admin, scope: :super_admin) }

      it 'shows the list of partners' do
        get '/super_admin/platform_apps'
        expect(response).to have_http_status(:success)
        expect(response.body).to include(CGI.escapeHTML(platform_app.name))
      end

      it 'explains in one line what the access is for and names the page in Russian' do
        get '/super_admin/platform_apps'

        expect(page.at_css('main h1').text.squish).to eq('Доступ по API для партнёров')
        expect(page.at_css('main .main-content__description').text.squish)
          .to eq('Ключи для систем партнёров: они создают аккаунты и пользователей через Platform API. Выдавайте только доверенным.')
        expect(page.at_css('main .main-content__actions a.button').text.squish).to eq('Новый партнёрский доступ')
        expect(main_text).not_to include('Платформенн')
      end

      it 'shows the last 4 characters of the token and how many accounts and users the partner owns, never the token' do
        create(:platform_app_permissible, platform_app: platform_app, permissible: create(:account))
        create(:platform_app_permissible, platform_app: platform_app, permissible: create(:user))
        create(:platform_app_permissible, platform_app: platform_app, permissible: create(:user))

        get '/super_admin/platform_apps'

        row = page.css('tbody tr').find { |tr| tr.text.include?(platform_app.name) }
        cells = row.css('td').map { |cell| cell.text.squish }
        expect(cells).to include("••••#{platform_app.access_token.token.last(4)}", '1', '2')
        expect(response.body).not_to include(platform_app.access_token.token)
      end

      it 'names the columns in Russian' do
        get '/super_admin/platform_apps'

        expect(page.css('thead th').map { |header| header.text.squish }.compact_blank)
          .to include('Название партнёра', 'Токен API')
      end
    end
  end

  describe 'POST /super_admin/platform_apps' do
    before { sign_in(super_admin, scope: :super_admin) }

    it 'creates the partner, shows its token once on the card and writes the audit log' do
      expect do
        post '/super_admin/platform_apps', params: { platform_app: { name: 'Портал клиник' } }
      end.to change(PlatformApp, :count).by(1)

      app = PlatformApp.find_by!(name: 'Портал клиник')
      expect(response).to redirect_to("/super_admin/platform_apps/#{app.id}")
      expect(flash[:notice]).to eq('Партнёрский доступ создан. Токен показан один раз: сохраните его сейчас.')

      follow_redirect!
      expect(page.at_css('[data-testid="one-time-token"] input')['value']).to eq(app.access_token.token)
      expect(response.headers['Cache-Control']).to include('no-store')

    end

    it 'writes the creation to the audit log without the token' do
      post '/super_admin/platform_apps', params: { platform_app: { name: 'Портал клиник' } }

      app = PlatformApp.find_by!(name: 'Портал клиник')
      audit = Audited::Audit.where(auditable: app, action: 'create').last
      expect(audit).to have_attributes(user_id: super_admin.id, comment: 'super_admin')
      expect(audit.audited_changes).to eq('name' => 'Портал клиник')
      expect(audit.audited_changes.to_s).not_to include(app.access_token.token)
    end

    it 'shows only the last 4 characters when the card is opened again' do
      post '/super_admin/platform_apps', params: { platform_app: { name: 'Портал клиник' } }
      app = PlatformApp.find_by!(name: 'Портал клиник')
      follow_redirect!

      get "/super_admin/platform_apps/#{app.id}"

      expect(page.at_css('[data-testid="one-time-token"]')).to be_nil
      expect(page.at_css('[data-testid="token-hint"]').text.squish).to include("••••#{app.access_token.token.last(4)}")
      expect(response.body).not_to include(app.access_token.token)
    end

    it 'does not draw the token as a flash message of the page shell' do
      post '/super_admin/platform_apps', params: { platform_app: { name: 'Портал клиник' } }
      app = PlatformApp.find_by!(name: 'Портал клиник')
      follow_redirect!

      expect(page.css('.flashes .flash').map { |flash| flash.text.squish })
        .to eq(['Партнёрский доступ создан. Токен показан один раз: сохраните его сейчас.'])
      expect(page.css('.flashes').to_s).not_to include(app.access_token.token)
    end

    it 'creates nothing and says why when the name is empty' do
      expect do
        post '/super_admin/platform_apps', params: { platform_app: { name: '' } }
      end.not_to change(PlatformApp, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe 'GET /super_admin/platform_apps/:id' do
    let!(:platform_app) { create(:platform_app, name: 'Портал клиник') }

    before { sign_in(super_admin, scope: :super_admin) }

    it 'lists the accounts and the users the partner created, with links to their cards' do
      account = create(:account, name: 'Аккаунт партнёра')
      user = create(:user, name: 'Сотрудник партнёра', email: 'worker@partner.test')
      create(:platform_app_permissible, platform_app: platform_app, permissible: account)
      create(:platform_app_permissible, platform_app: platform_app, permissible: user)
      stranger = create(:account, name: 'Чужой аккаунт')

      get "/super_admin/platform_apps/#{platform_app.id}"

      accounts = page.at_css('[data-testid="partner-accounts"]')
      users = page.at_css('[data-testid="partner-users"]')
      expect(accounts.text).to include('Аккаунт партнёра')
      expect(accounts.at_css('a')['href']).to eq("/super_admin/accounts/#{account.id}")
      expect(accounts.text).not_to include(stranger.name)
      expect(users.text).to include('Сотрудник партнёра', 'worker@partner.test')
      expect(users.at_css('a')['href']).to eq("/super_admin/users/#{user.id}")
    end

    it 'says that the partner has created nothing yet' do
      get "/super_admin/platform_apps/#{platform_app.id}"

      expect(main_text).to include('Партнёр ещё не создал ни одного аккаунта.', 'Партнёр ещё не создал ни одного пользователя.')
    end

    it 'offers the reissue of the token, editing and deleting of the access' do
      get "/super_admin/platform_apps/#{platform_app.id}"

      buttons = page.css('main .main-content__actions').text.squish
      expect(buttons).to include('Перевыпустить токен', 'Редактировать', 'Удалить')
      expect(page.at_css('main form[action$="/reissue_token"]')).to be_present
    end
  end

  describe 'PATCH /super_admin/platform_apps/:id' do
    let!(:platform_app) { create(:platform_app, name: 'Старое имя') }

    before { sign_in(super_admin, scope: :super_admin) }

    it 'renames the partner and writes what changed to the audit log' do
      patch "/super_admin/platform_apps/#{platform_app.id}", params: { platform_app: { name: 'Новое имя' } }

      expect(response).to redirect_to("/super_admin/platform_apps/#{platform_app.id}")
      expect(flash[:notice]).to eq('Партнёрский доступ сохранён.')
      expect(platform_app.reload.name).to eq('Новое имя')
      audit = Audited::Audit.where(auditable: platform_app, action: 'update').last
      expect(audit.audited_changes).to eq('name' => ['Старое имя', 'Новое имя'])
      expect(audit.user_id).to eq(super_admin.id)
    end

    it 'writes nothing to the audit log when nothing changed' do
      expect do
        patch "/super_admin/platform_apps/#{platform_app.id}", params: { platform_app: { name: 'Старое имя' } }
      end.not_to change(Audited::Audit, :count)
    end
  end

  describe 'POST /super_admin/platform_apps/:id/reissue_token' do
    let!(:platform_app) { create(:platform_app) }

    context 'when it is an unauthenticated super admin' do
      it 'redirects to the login and keeps the token' do
        old_token = platform_app.access_token.token

        post "/super_admin/platform_apps/#{platform_app.id}/reissue_token"

        expect(response).to have_http_status(:redirect)
        expect(platform_app.reload.access_token.token).to eq(old_token)
      end
    end

    context 'when it is an authenticated super admin' do
      before { sign_in(super_admin, scope: :super_admin) }

      it 'replaces the token, shows the new one once and writes the audit log without any token' do
        old_token = platform_app.access_token.token

        post "/super_admin/platform_apps/#{platform_app.id}/reissue_token"

        new_token = platform_app.reload.access_token.token
        expect(new_token).not_to eq(old_token)
        expect(response).to redirect_to("/super_admin/platform_apps/#{platform_app.id}")
        expect(flash[:notice]).to eq('Токен перевыпущен. Старый токен больше не работает; новый показан один раз.')

        follow_redirect!
        expect(page.at_css('[data-testid="one-time-token"] input')['value']).to eq(new_token)
        expect(response.body).not_to include(old_token)

        audit = Audited::Audit.where(auditable: platform_app, action: 'reissue_token').last
        expect(audit).to have_attributes(user_id: super_admin.id)
        expect(audit.audited_changes.to_s).not_to include(old_token, new_token)
      end

      it 'stops the old token from working in the Platform API at once' do
        old_token = platform_app.access_token.token
        post "/super_admin/platform_apps/#{platform_app.id}/reissue_token"

        get '/platform/api/v1/accounts', headers: { api_access_token: old_token }, as: :json

        expect(response).to have_http_status(:unauthorized)
      end

      it 'shows the token once only: the next page view has the last 4 characters' do
        post "/super_admin/platform_apps/#{platform_app.id}/reissue_token"
        follow_redirect!
        expect(page.at_css('[data-testid="one-time-token"]')).to be_present

        get "/super_admin/platform_apps/#{platform_app.id}"

        expect(page.at_css('[data-testid="one-time-token"]')).to be_nil
        expect(response.body).not_to include(platform_app.reload.access_token.token)
      end
    end
  end

  describe 'DELETE /super_admin/platform_apps/:id' do
    let!(:platform_app) { create(:platform_app) }
    let(:access_token) { platform_app.access_token }

    context 'when it is an unauthenticated super admin' do
      it 'returns unauthorized' do
        delete "/super_admin/platform_apps/#{platform_app.id}", params: { _method: :delete }
        expect(response).to have_http_status(:redirect)
      end
    end

    context 'when it is an authenticated super admin' do
      before { sign_in(super_admin, scope: :super_admin) }

      it 'deletes the platform app' do
        expect do
          delete "/super_admin/platform_apps/#{platform_app.id}", params: { _method: :delete }
        end.to change(PlatformApp, :count).by(-1)
        expect(response).to have_http_status(:redirect)
        expect(response).to redirect_to(super_admin_platform_apps_path)
        expect(flash[:notice]).to eq('Партнёрский доступ удалён. Его токен больше не работает.')
      end

      it 'writes the audit log with the name and the number of accounts and users' do
        create(:platform_app_permissible, platform_app: platform_app, permissible: create(:account))

        delete "/super_admin/platform_apps/#{platform_app.id}"

        audit = Audited::Audit.where(auditable_type: 'PlatformApp', auditable_id: platform_app.id, action: 'destroy').last
        expect(audit.audited_changes).to eq('name' => platform_app.name, 'accounts' => 1, 'users' => 0)
        expect(audit.user_id).to eq(super_admin.id)
      end
    end
  end
end
