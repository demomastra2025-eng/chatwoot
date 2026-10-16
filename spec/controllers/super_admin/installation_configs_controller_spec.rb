require 'rails_helper'

RSpec.describe 'Super Admin Installation Config API', type: :request do
  let(:super_admin) { create(:super_admin) }

  describe 'GET /super_admin/installation_configs/new' do
    context 'when it is an unauthenticated super admin' do
      it 'returns unauthorized' do
        get '/super_admin/installation_configs/new'
        expect(response).to have_http_status(:redirect)
      end
    end

    context 'when it is an authenticated super admin' do
      let(:config) { create(:installation_config, { name: 'TESTCONFIG', value: 'TESTVALUE', locked: false }) }

      before do
        config
      end

      it 'shows the installation_configs create page' do
        sign_in(super_admin, scope: :super_admin)
        get '/super_admin/installation_configs/new'
        expect(response).to have_http_status(:success)
      end

      it 'shows the installation_configs edit page' do
        sign_in(super_admin, scope: :super_admin)
        editable_config = InstallationConfig.editable.first
        get "/super_admin/installation_configs/#{editable_config.id}/edit"
        expect(response).to have_http_status(:success)
      end

      it 'shows the installation_configs list page' do
        sign_in(super_admin, scope: :super_admin)
        get '/super_admin/installation_configs'
        expect(response).to have_http_status(:success)
        expect(response.body).to include(config.name)
      end
    end
  end

  describe 'the platform switch of the channels' do
    let(:name) { Channels::PlatformVisibility::CONFIG_NAME }
    let!(:visibility) { Channels::PlatformVisibility.update!({ 'api' => 'shown' }) && InstallationConfig.find_by!(name: name) }

    before { sign_in(super_admin, scope: :super_admin) }

    it 'is not in the list of the generic editor, which still lists the other configs' do
      other = create(:installation_config, name: 'TESTCONFIG', value: 'TESTVALUE', locked: false)

      get '/super_admin/installation_configs'

      expect(response).to have_http_status(:success)
      expect(response.body).to include(other.name)
      expect(response.body).not_to include(name)
    end

    it 'cannot be opened or edited by its id' do
      get "/super_admin/installation_configs/#{visibility.id}"
      expect(response).to have_http_status(:not_found)

      get "/super_admin/installation_configs/#{visibility.id}/edit"
      expect(response).to have_http_status(:not_found)

      patch "/super_admin/installation_configs/#{visibility.id}", params: { installation_config: { value: '{"api":"hidden"}' } }
      expect(response).to have_http_status(:not_found)
      expect(Channels::PlatformVisibility.settings).to eq('api' => 'shown')
    end

    it 'cannot be created or taken over by renaming another config, and says where it is set' do
      InstallationConfig.where(name: name).delete_all

      post '/super_admin/installation_configs', params: { installation_config: { name: name, value: '{"api":"shown"}' } }

      expect(response).to redirect_to('/super_admin/installation_configs')
      expect(flash[:alert]).to eq("Параметр «#{name}» настраивается на странице «Каналы», здесь его менять нельзя.")
      expect(InstallationConfig.where(name: name)).to be_empty

      other = create(:installation_config, name: 'TESTCONFIG', value: 'TESTVALUE', locked: false)
      patch "/super_admin/installation_configs/#{other.id}", params: { installation_config: { name: name, value: 'x' } }

      expect(flash[:alert]).to include('Каналы')
      expect(other.reload.name).to eq('TESTCONFIG')
    end

    it 'is still saved from the Каналы page' do
      patch '/super_admin/channels', params: { channels: { 'sms' => 'shown' } }

      expect(Channels::PlatformVisibility.settings).to eq('api' => 'shown', 'sms' => 'shown')
    end
  end
end
