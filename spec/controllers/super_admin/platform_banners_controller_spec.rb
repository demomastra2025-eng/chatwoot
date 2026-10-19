require 'rails_helper'

RSpec.describe 'Super Admin platform banners', type: :request do
  let(:super_admin) { create(:super_admin) }

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

  describe 'POST /super_admin/platform_banners' do
    it 'creates a banner' do
      sign_in(super_admin, scope: :super_admin)

      expect do
        post '/super_admin/platform_banners', params: {
          platform_banner: {
            banner_message: 'Scheduled provider maintenance',
            banner_type: 'warning',
            active: '1'
          }
        }
      end.to change(PlatformBanner, :count).by(1)

      banner = PlatformBanner.last
      expect(banner.banner_message).to eq('Scheduled provider maintenance')
      expect(banner).to be_warning
      expect(response).to redirect_to(super_admin_platform_banner_path(banner))
    end
  end

  describe 'DELETE /super_admin/platform_banners/:id' do
    let!(:banner) { create(:platform_banner) }

    it 'deletes a banner' do
      sign_in(super_admin, scope: :super_admin)

      expect do
        delete "/super_admin/platform_banners/#{banner.id}", params: { _method: :delete }
      end.to change(PlatformBanner, :count).by(-1)

      expect(response).to redirect_to(super_admin_platform_banners_path)
    end
  end

  context 'when the instance is self-hosted' do
    before do
      allow(ChatwootApp).to receive(:chatwoot_cloud?).and_return(false)
      sign_in(super_admin, scope: :super_admin)
    end

    it 'shows the list, with the line that says what a banner is for' do
      create(:platform_banner, banner_message: 'Технические работы в субботу')

      get '/super_admin/platform_banners'

      expect(response).to have_http_status(:success)
      expect(response.body).to include('Технические работы в субботу', 'например о технических работах')
    end

    it 'creates a banner that the operator app gets with its settings' do
      post '/super_admin/platform_banners', params: { platform_banner: { banner_message: 'Работы с 22:00', banner_type: 'warning', active: '1' } }

      expect(response).to redirect_to(super_admin_platform_banner_path(PlatformBanner.last))
      expect(DashboardController.new.send(:active_platform_banners).pluck('banner_message')).to eq(['Работы с 22:00'])
    end
  end
end
