require 'rails_helper'

RSpec.describe 'Super Admin platform banners', type: :request do
  let(:super_admin) { create(:super_admin) }

  def page = Nokogiri::HTML(response.body)

  def text(node) = node.text.squish

  def audits(action) = Audited::Audit.where(auditable_type: 'PlatformBanner', action: action)

  describe 'GET /super_admin/platform_banners' do
    context 'when unauthenticated' do
      it 'redirects to login' do
        get '/super_admin/platform_banners'

        expect(response).to have_http_status(:redirect)
      end
    end

    context 'when authenticated' do
      let(:banner) { create(:platform_banner, banner_message: 'Meta API outage') }

      it 'shows the banner list' do
        sign_in(super_admin, scope: :super_admin)
        banner

        get '/super_admin/platform_banners'

        expect(response).to have_http_status(:success)
        expect(response.body).to include('Meta API outage')
      end
    end
  end

  # A banner reaches the operators of EVERY account, so it is made hidden and shown by its own action, which asks first
  describe 'POST /super_admin/platform_banners' do
    before { sign_in(super_admin, scope: :super_admin) }

    it 'creates a banner that is hidden, whatever the request says' do
      expect do
        post '/super_admin/platform_banners', params: {
          platform_banner: { banner_message: 'Scheduled provider maintenance', banner_type: 'warning', active: '1' }
        }
      end.to change(PlatformBanner, :count).by(1)

      banner = PlatformBanner.last
      expect(banner.banner_message).to eq('Scheduled provider maintenance')
      expect(banner).to be_warning
      expect(banner).not_to be_active
      expect(response).to redirect_to(super_admin_platform_banner_path(banner))
      expect(flash[:notice]).to include('пока не показывается', 'Показать всем операторам')
    end

    it 'writes the creation to the audit log' do
      post '/super_admin/platform_banners', params: { platform_banner: { banner_message: 'Работы с 22:00', banner_type: 'info' } }

      audit = audits('create').last
      expect(audit).to have_attributes(auditable_id: PlatformBanner.last.id, user_id: super_admin.id, comment: 'super_admin')
      expect(audit.audited_changes).to include('banner_message' => 'Работы с 22:00', 'active' => false)
    end

    it 'draws the new form without the switch «активен» and says that the banner starts hidden' do
      get '/super_admin/platform_banners/new'

      expect(page.css('input[name="platform_banner[active]"]')).to be_empty
      expect(page.css('textarea[name="platform_banner[banner_message]"], select[name="platform_banner[banner_type]"]').size).to eq(2)
    end

    it 'does not create a banner without a text, and shows what was typed' do
      expect do
        post '/super_admin/platform_banners', params: { platform_banner: { banner_message: '', banner_type: 'error' } }
      end.not_to change(PlatformBanner, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe 'the card of a banner' do
    before { sign_in(super_admin, scope: :super_admin) }

    it 'shows a hidden banner with its preview and the question before it is shown to everybody', :aggregate_failures do
      create(:account, status: :suspended)
      create_list(:account, 2)
      banner = create(:platform_banner, banner_message: 'Работы в субботу', banner_type: :warning, active: false)

      get "/super_admin/platform_banners/#{banner.id}"

      expect(text(page.at_css('[data-testid="banner-state"]'))).to eq('Не показывается')
      expect(text(page.at_css('[data-testid="banner-preview"]'))).to include('Работы в субботу', 'пока не показывается')
      expect(page.at_css('[data-testid="banner-preview"] .admin-notice--amber')).to be_present
      node = page.at_css('[data-testid="confirm-publish-banner"]')
      expect(text(node.at_css('summary'))).to eq('Показать всем операторам')
      expect(text(node.at_css('.admin-ask__title'))).to eq('Показать баннер всем операторам?')
      reach = "операторы всех активных аккаунтов (сейчас их #{PlatformBanner.reach})"
      expect(text(node.at_css('.admin-ask__panel'))).to include(reach, 'журнал аудита')
      expect(text(node.at_css('[data-testid="publish-preview"]'))).to eq('Работы в субботу')
      expect(node.at_css('form')['action']).to eq("/super_admin/platform_banners/#{banner.id}/publish")
      expect(text(node.at_css('button[type="submit"]'))).to eq('Да, показать всем')
      expect(page.css('[data-confirm]')).to be_empty
    end

    it 'counts the active accounts only, a blocked account does not serve its operators' do
      create(:account, status: :suspended)
      create_list(:account, 2)

      expect(PlatformBanner.reach).to eq(Account.active.count)
      expect(PlatformBanner.reach).to be < Account.count
    end

    it 'colours the preview by the type of the banner' do
      { info: 'admin-notice--blue', warning: 'admin-notice--amber', error: 'admin-notice--ruby' }.each do |type, css|
        banner = create(:platform_banner, banner_type: type, active: false)

        get "/super_admin/platform_banners/#{banner.id}"

        expect(page.at_css("[data-testid='banner-preview'] .#{css}")).to be_present
      end
    end

    it 'shows a banner that is shown, with «Скрыть у всех» instead of the question' do
      banner = create(:platform_banner, active: true)

      get "/super_admin/platform_banners/#{banner.id}"

      expect(text(page.at_css('[data-testid="banner-state"]'))).to eq('Показывается всем')
      expect(page.at_css('[data-testid="confirm-publish-banner"]')).to be_nil
      expect(page.at_css("form[action='/super_admin/platform_banners/#{banner.id}/hide']")).to be_present
    end

    it 'does not draw a message as markup' do
      banner = create(:platform_banner, banner_message: '<script>alert(1)</script> [ссылка](https://example.test)', active: false)

      get "/super_admin/platform_banners/#{banner.id}"

      expect(response.body).not_to include('<script>alert(1)</script>')
    end
  end

  describe 'POST /super_admin/platform_banners/:id/publish' do
    let!(:banner) { create(:platform_banner, banner_message: 'Работы с 22:00', active: false) }

    before { sign_in(super_admin, scope: :super_admin) }

    it 'shows the banner to the operators from now on' do
      expect(DashboardController.new.send(:active_platform_banners)).to be_empty

      post "/super_admin/platform_banners/#{banner.id}/publish"

      expect(response).to redirect_to(super_admin_platform_banner_path(banner))
      expect(flash[:notice]).to eq("Баннер показывается операторам всех активных аккаунтов (#{PlatformBanner.reach}).")
      expect(banner.reload).to be_active
      expect(DashboardController.new.send(:active_platform_banners).pluck('banner_message')).to eq(['Работы с 22:00'])
    end

    it 'writes who showed it to how many accounts' do
      create(:account)

      post "/super_admin/platform_banners/#{banner.id}/publish"

      audit = audits('publish_banner').last
      expect(audit).to have_attributes(auditable_id: banner.id, user_id: super_admin.id)
      expect(audit.audited_changes).to include('banner_message' => 'Работы с 22:00', 'active' => true, 'accounts' => PlatformBanner.reach)
    end

    it 'says so, and writes nothing, when the banner is shown already' do
      banner.update!(active: true)

      expect { post "/super_admin/platform_banners/#{banner.id}/publish" }.not_to(change { audits('publish_banner').count })

      expect(flash[:alert]).to eq('Баннер уже показывается.')
    end

    it 'is not open to a visitor who has not signed in' do
      sign_out(:super_admin)

      post "/super_admin/platform_banners/#{banner.id}/publish"

      expect(banner.reload).not_to be_active
    end
  end

  describe 'POST /super_admin/platform_banners/:id/hide' do
    let!(:banner) { create(:platform_banner, active: true) }

    before { sign_in(super_admin, scope: :super_admin) }

    it 'takes the banner off the screens of the operators and writes it down' do
      post "/super_admin/platform_banners/#{banner.id}/hide"

      expect(flash[:notice]).to eq('Баннер скрыт: операторы его больше не видят.')
      expect(banner.reload).not_to be_active
      expect(DashboardController.new.send(:active_platform_banners)).to be_empty
      expect(audits('hide_banner').last).to have_attributes(auditable_id: banner.id, user_id: super_admin.id)
    end

    it 'says so when the banner is hidden already' do
      banner.update!(active: false)

      post "/super_admin/platform_banners/#{banner.id}/hide"

      expect(flash[:alert]).to eq('Баннер уже скрыт.')
      expect(audits('hide_banner')).to be_empty
    end
  end

  describe 'editing a banner' do
    before { sign_in(super_admin, scope: :super_admin) }

    it 'warns that what is saved is seen at once when the banner is shown' do
      banner = create(:platform_banner, active: true)

      get "/super_admin/platform_banners/#{banner.id}/edit"

      expect(text(page.at_css('[data-testid="banner-live-note"]'))).to include('сейчас показывается', 'Изменения они увидят сразу')
    end

    it 'does not warn about a banner that is hidden' do
      banner = create(:platform_banner, active: false)

      get "/super_admin/platform_banners/#{banner.id}/edit"

      expect(page.at_css('[data-testid="banner-live-note"]')).to be_nil
    end

    it 'saves the text and the type, never the switch, and writes the change' do
      banner = create(:platform_banner, banner_message: 'Старый текст', banner_type: :info, active: false)

      form = { banner_message: 'Новый текст', banner_type: 'error', active: '1' }
      patch "/super_admin/platform_banners/#{banner.id}", params: { platform_banner: form }

      expect(response).to redirect_to(super_admin_platform_banner_path(banner))
      expect(banner.reload).to have_attributes(banner_message: 'Новый текст', banner_type: 'error', active: false)
      expect(audits('update').last.audited_changes).to include('banner_message' => ['Старый текст', 'Новый текст'])
    end

    it 'writes nothing when nothing changed' do
      banner = create(:platform_banner, banner_message: 'Текст', active: false)

      expect do
        patch "/super_admin/platform_banners/#{banner.id}", params: { platform_banner: { banner_message: 'Текст' } }
      end.not_to(change { audits('update').count })
    end
  end

  describe 'DELETE /super_admin/platform_banners/:id' do
    let!(:banner) { create(:platform_banner, banner_message: 'Старый баннер') }

    before { sign_in(super_admin, scope: :super_admin) }

    it 'deletes a banner and writes it down' do
      expect do
        delete "/super_admin/platform_banners/#{banner.id}", params: { _method: :delete }
      end.to change(PlatformBanner, :count).by(-1)

      expect(response).to redirect_to(super_admin_platform_banners_path)
      expect(audits('destroy').last).to have_attributes(auditable_id: banner.id, user_id: super_admin.id)
      expect(audits('destroy').last.audited_changes).to include('banner_message' => 'Старый баннер')
    end

    it 'asks first, on the card and in the list' do
      get "/super_admin/platform_banners/#{banner.id}"
      node = page.at_css('[data-testid="confirm-delete-banner"]')
      expect(text(node.at_css('.admin-ask__title'))).to eq('Удалить баннер «Старый баннер»?')
      expect(text(node.at_css('.admin-ask__panel'))).to include('сразу пропадёт у всех операторов')
      expect(page.css('[data-confirm]')).to be_empty

      get '/super_admin/platform_banners'
      expect(page.at_css("[data-testid='confirm-delete-platform_banner-#{banner.id}']")).to be_present
      expect(page.css('[data-confirm]')).to be_empty
    end
  end

  context 'when the instance is self-hosted' do
    before do
      allow(ChatwootApp).to receive(:chatwoot_cloud?).and_return(false)
      sign_in(super_admin, scope: :super_admin)
    end

    it 'shows the list, with the line that says what a banner is for and that a new one starts hidden' do
      create(:platform_banner, banner_message: 'Технические работы в субботу')

      get '/super_admin/platform_banners'

      expect(response).to have_http_status(:success)
      expect(response.body).to include('Технические работы в субботу', 'например о технических работах', 'Новый баннер сначала скрыт')
    end

    it 'creates a banner that the operator app gets with its settings once it is shown' do
      post '/super_admin/platform_banners', params: { platform_banner: { banner_message: 'Работы с 22:00', banner_type: 'warning' } }
      banner = PlatformBanner.last
      expect(DashboardController.new.send(:active_platform_banners)).to be_empty

      post "/super_admin/platform_banners/#{banner.id}/publish"

      expect(response).to redirect_to(super_admin_platform_banner_path(banner))
      expect(DashboardController.new.send(:active_platform_banners).pluck('banner_message')).to eq(['Работы с 22:00'])
    end
  end
end
