require 'rails_helper'

RSpec.describe 'Super Admin Installation Config API', type: :request do
  let(:super_admin) { create(:super_admin) }

  def page = Nokogiri::HTML(response.body)

  def row_of(name) = page.at_css(%(tr[data-config-name="#{name}"]))

  describe 'GET /super_admin/installation_configs' do
    context 'when it is an unauthenticated super admin' do
      it 'returns unauthorized' do
        get '/super_admin/installation_configs'
        expect(response).to have_http_status(:redirect)
      end
    end

    context 'when it is an authenticated super admin' do
      before { sign_in(super_admin, scope: :super_admin) }

      it 'lists the parameters that the settings pages saved' do
        config = create(:installation_config, name: 'TESTCONFIG', value: 'TESTVALUE', locked: false)

        get '/super_admin/installation_configs'

        expect(response).to have_http_status(:success)
        expect(response.body).to include(config.name)
      end

      it 'shows the value of an ordinary parameter, cut when it is long' do
        upsert_installation_config('FB_APP_ID', 'visible-app-id', locked: false)
        upsert_installation_config('FACEBOOK_API_VERSION', 'v' + ('x' * 400), locked: false)

        get '/super_admin/installation_configs'

        expect(row_of('FB_APP_ID').text).to include('visible-app-id')
        shown = row_of('FACEBOOK_API_VERSION').at_css('[data-testid="config-value"]').text
        expect(shown.length).to be <= SuperAdmin::InstallationConfigs::VALUE_LIMIT
        expect(shown).to end_with('...')
      end

      it 'never puts the value of a secret into the page and says only that it is set' do
        upsert_installation_config('FB_APP_SECRET', 'super-secret-value-123456', locked: false)
        upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', 'sk-or-v1-abcdef0123456789', locked: false)
        upsert_installation_config('FIREBASE_CREDENTIALS', '{"private_key":"-----BEGIN PRIVATE KEY-----abc"}', locked: false)

        get '/super_admin/installation_configs'

        expect(response.body).not_to include('super-secret-value-123456', 'abcdef0123456789', 'BEGIN PRIVATE KEY', 'sk-or-v1')
        %w[FB_APP_SECRET CAPTAIN_OPENROUTER_API_KEY FIREBASE_CREDENTIALS].each do |name|
          expect(row_of(name).at_css('[data-testid="config-secret"]').text.squish).to eq('задан')
        end
      end

      it 'does not even print the last characters of a secret' do
        upsert_installation_config('FB_APP_SECRET', 'secret-ending-in-QWERTY', locked: false)

        get '/super_admin/installation_configs'

        expect(response.body).not_to include('QWERTY')
      end

      it 'hides the value of a row the catalogue does not know, which can hold anything' do
        create(:installation_config, name: 'SOMETHING_ELSE', value: 'maybe-a-password', locked: false)

        get '/super_admin/installation_configs'

        expect(response.body).not_to include('maybe-a-password')
        expect(row_of('SOMETHING_ELSE').at_css('[data-testid="config-hidden"]').text.squish).to eq('скрыто')
      end

      it 'links each parameter to the settings page that edits it' do
        upsert_installation_config('FB_APP_ID', 'app-id', locked: false)
        upsert_installation_config('ENABLE_ACCOUNT_SIGNUP', 'false', locked: false)
        create(:installation_config, name: 'SOMETHING_ELSE', value: 'x', locked: false)

        get '/super_admin/installation_configs'

        expect(row_of('FB_APP_ID').at_css('a[href="/super_admin/app_config?config=facebook"]').text.squish).to eq('Facebook & Messenger')
        expect(row_of('ENABLE_ACCOUNT_SIGNUP').at_css('a[href="/super_admin/app_config?config=general"]')).to be_present
        expect(row_of('SOMETHING_ELSE').css('a').map { |link| link['href'] }).to eq(['/super_admin/installation_configs/' \
                                                                                    "#{InstallationConfig.find_by!(name: 'SOMETHING_ELSE').id}"])
      end

      it 'does not find a secret by searching for its value' do
        upsert_installation_config('FB_APP_SECRET', 'needle-in-a-haystack', locked: false)

        get '/super_admin/installation_configs', params: { search: 'needle-in-a-haystack' }

        expect(response).to have_http_status(:success)
        expect(page.css('tr[data-config-name]')).to be_empty
      end

      it 'has no button that creates a parameter and no edit or delete link' do
        create(:installation_config, name: 'TESTCONFIG', value: 'TESTVALUE', locked: false)

        get '/super_admin/installation_configs'

        expect(page.css('main .main-content__actions a.button')).to be_empty
        expect(page.css('a[href*="/edit"], a[href$="/new"]')).to be_empty
        expect(page.css('a[data-method="delete"]')).to be_empty
        expect(page.at_css('main .main-content__description').text).to include('только для чтения')
      end
    end
  end

  describe 'GET /super_admin/installation_configs/:id' do
    before { sign_in(super_admin, scope: :super_admin) }

    it 'shows a parameter with its settings page, and a secret without its value' do
      config = upsert_installation_config('WHATSAPP_APP_SECRET', 'wa-secret-value-98765', locked: false)

      get "/super_admin/installation_configs/#{config.id}"

      expect(response).to have_http_status(:success)
      expect(response.body).not_to include('wa-secret-value-98765', '98765')
      expect(page.at_css('main').text).to include('WHATSAPP_APP_SECRET', 'задан')
      expect(page.at_css('main a[href="/super_admin/app_config?config=whatsapp_embedded"]')).to be_present
      expect(page.css('main a[href*="/edit"]')).to be_empty
    end
  end

  describe 'what cannot be done to a parameter here' do
    before { sign_in(super_admin, scope: :super_admin) }

    it 'has no route to create, change, rename or delete one' do
      config = create(:installation_config, name: 'TESTCONFIG', value: 'TESTVALUE', locked: false)
      router = Rails.application.routes

      expect { router.recognize_path('/super_admin/installation_configs', method: 'POST') }.to raise_error(ActionController::RoutingError)
      expect { router.recognize_path("/super_admin/installation_configs/#{config.id}", method: 'PATCH') }.to raise_error(ActionController::RoutingError)
      expect { router.recognize_path("/super_admin/installation_configs/#{config.id}", method: 'PUT') }.to raise_error(ActionController::RoutingError)
      expect { router.recognize_path("/super_admin/installation_configs/#{config.id}", method: 'DELETE') }.to raise_error(ActionController::RoutingError)
      expect { router.recognize_path("/super_admin/installation_configs/#{config.id}/edit", method: 'GET') }.to raise_error(ActionController::RoutingError)
    end

    it 'does not open a form for a new parameter' do
      get '/super_admin/installation_configs/new'

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'the platform switch of the channels' do
    let(:name) { Channels::PlatformVisibility::CONFIG_NAME }
    let!(:visibility) { Channels::PlatformVisibility.update!({ 'api' => 'shown' }) && InstallationConfig.find_by!(name: name) }

    before { sign_in(super_admin, scope: :super_admin) }

    it 'is not in the list, which still lists the other configs' do
      other = create(:installation_config, name: 'TESTCONFIG', value: 'TESTVALUE', locked: false)

      get '/super_admin/installation_configs'

      expect(response).to have_http_status(:success)
      expect(response.body).to include(other.name)
      expect(response.body).not_to include(name)
    end

    # a 404 ends the session of the test client, so every page is asked for in an example of its own
    it 'cannot be opened by its id' do
      get "/super_admin/installation_configs/#{visibility.id}"

      expect(response).to have_http_status(:not_found)
    end

    it 'is still saved from the Каналы page' do
      patch '/super_admin/channels', params: { channels: { 'sms' => 'shown' } }

      expect(Channels::PlatformVisibility.settings).to eq('api' => 'shown', 'sms' => 'shown')
    end
  end
end
