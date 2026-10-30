require 'rails_helper'

describe '/app/login', type: :request do
  context 'without DEFAULT_LOCALE' do
    it 'renders the dashboard' do
      get '/app/login'
      expect(response).to have_http_status(:success)
    end

    it 'uses a scrollable document layout for auth pages' do
      ['/app/login', '/app/auth/signup'].each do |path|
        get path

        document = Nokogiri::HTML(response.body)
        html_class = document.at_css('html')['class']
        body_class = document.at_css('body')['class']

        expect(html_class).to include('auth-page-scrollable')
        expect(body_class).to include('auth-page-scrollable')
        expect(html_class.split).not_to include('overflow-hidden')
        expect(body_class.split).not_to include('overflow-hidden')
      end
    end

    it 'renders OpenGraph preview metadata with absolute PNG logo URL when DISPLAY_MANIFEST is enabled' do
      InstallationConfig.find_or_initialize_by(name: 'DISPLAY_MANIFEST').update!(value: true)
      InstallationConfig.find_or_initialize_by(name: 'INSTALLATION_NAME').update!(value: 'OneLink')
      GlobalConfig.clear_cache

      with_modified_env FRONTEND_URL: 'https://app.one-link.kz' do
        get '/app/login'

        document = Nokogiri::HTML(response.body)
        expect(document.at_css('meta[property="og:type"]')['content']).to eq('website')
        expect(document.at_css('meta[property="og:title"]')['content']).to eq('OneLink')
        expect(document.at_css('meta[property="og:description"]')['content']).to include('это решение для поддержки клиентов')
        expect(document.at_css('meta[property="og:url"]')['content']).to eq('https://app.one-link.kz/')
        expect(document.at_css('meta[property="og:image"]')['content']).to eq('https://app.one-link.kz/favicon-512x512.png')
        expect(document.at_css('meta[property="og:image:width"]')['content']).to eq('512')
        expect(document.at_css('meta[property="og:image:height"]')['content']).to eq('512')
      end
    ensure
      GlobalConfig.clear_cache
    end

    it 'omits og:url and og:image instead of reflecting Host when FRONTEND_URL is blank' do
      InstallationConfig.find_or_initialize_by(name: 'DISPLAY_MANIFEST').update!(value: true)
      GlobalConfig.clear_cache

      with_modified_env FRONTEND_URL: '' do
        get '/app/login', headers: { 'Host' => 'untrusted.example' }

        document = Nokogiri::HTML(response.body)
        expect(document.at_css('meta[property="og:url"]')).to be_nil
        expect(document.at_css('meta[property="og:image"]')).to be_nil
      end
    ensure
      GlobalConfig.clear_cache
    end

    it 'keeps the dashboard shell locked to the viewport' do
      get '/app'

      document = Nokogiri::HTML(response.body)
      html_class = document.at_css('html')['class']
      body_class = document.at_css('body')['class']

      expect(html_class.split).to include('h-full', 'overflow-hidden')
      expect(body_class.split).to include('h-full', 'overflow-hidden')
      expect(html_class).not_to include('auth-page-scrollable')
      expect(body_class).not_to include('auth-page-scrollable')
    end

    it 'renders the configured WhatsApp Graph API version for embedded signup' do
      allow(GlobalConfigService).to receive(:load).and_call_original
      allow(GlobalConfigService).to receive(:load).with('WHATSAPP_API_VERSION', 'v25.0').and_return('v25.0')

      get '/app'

      expect(response.body).to include("whatsappApiVersion: 'v25.0'")
    end

    it 'keeps proactive reauthorization hidden by default' do
      allow(GlobalConfigService).to receive(:load).and_call_original
      allow(GlobalConfigService).to receive(:load).with('WHATSAPP_PROACTIVE_REAUTHORIZATION_ENABLED', false).and_return(false)

      get '/app'

      expect(response.body).to include('whatsappProactiveReauthorizationEnabled: false')
    end

    it 'exposes proactive reauthorization after rollout activation' do
      allow(GlobalConfigService).to receive(:load).and_call_original
      allow(GlobalConfigService).to receive(:load).with('WHATSAPP_PROACTIVE_REAUTHORIZATION_ENABLED', false).and_return('true')

      get '/app'

      expect(response.body).to include('whatsappProactiveReauthorizationEnabled: true')
    end
  end

  context 'with configured DEFAULT_LOCALE' do
    it 'renders the dashboard' do
      with_modified_env DEFAULT_LOCALE: 'en_US' do
        get '/app/login'
        expect(response).to have_http_status(:success)
        expect(response.body).to include "selectedLocale: 'en'"
      end
    end
  end

  context 'with non-HTML format' do
    it 'returns not acceptable for JSON with error message' do
      get '/app/login', headers: { 'Accept' => 'application/json' }
      expect(response).to have_http_status(:not_acceptable)
      expect(response.parsed_body).to eq({ 'error' => 'Please use API routes instead of dashboard routes for JSON requests' })
    end
  end

  # Routes are loaded once on app start
  # hence Rails.application.reload_routes! is used in this spec
  # ref : https://stackoverflow.com/a/63584877/939299
  context 'with CW_API_ONLY_SERVER true' do
    it 'returns 404' do
      with_modified_env CW_API_ONLY_SERVER: 'true' do
        Rails.application.reload_routes!
        get '/app/login'
        expect(response).to have_http_status(:not_found)
      end
      Rails.application.reload_routes!
    end
  end
end
