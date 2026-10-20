require 'rails_helper'

# The contents of the settings: every page of the settings with one line about what it holds and whether it is set up, no
# showcase of the functions of the platform, and the version of the build that is running (small, in the page and in the menu).
RSpec.describe 'Super admin contents of the settings', type: :request do
  let(:super_admin) { create(:super_admin) }

  before do
    allow(ChatwootHub).to receive(:pricing_plan).and_return('enterprise')
    sign_in(super_admin, scope: :super_admin)
  end

  # The page of the last response (read again after every request of the example)
  def page = Nokogiri::HTML(response.body)

  def text(node)
    node.text.squish
  end

  describe 'the contents of the settings' do
    before { InstallationConfig.where(name: SuperAdmin::AppConfigStatus::REQUIRED.values.flatten).delete_all }

    def rows
      page.css('[data-page]').index_by { |row| row['data-page'] }
    end

    it 'lists every page of the settings, in two groups, each with a link and one line about what it holds' do
      get '/super_admin/settings'

      expect(response).to have_http_status(:ok)
      expect(text(page.at_css('h1'))).to eq('Настройки платформы')
      expect(page.css('[data-testid^="settings-group-"] h2').map { |heading| text(heading) }).to eq(['Платформа', 'Каналы и интеграции'])
      expect(rows.keys).to eq(%w[general captain custom_branding email facebook instagram tiktok whatsapp_embedded google microsoft slack])
      rows.each do |config, row|
        expect(row.at_css('a')['href']).to eq("/super_admin/app_config?config=#{config}")
        expect(text(row.at_css('.admin-field__hint'))).to match(/\p{Cyrillic}/)
      end
      expect(response.body).not_to include('translation missing')
    end

    it 'says for every page that has something to connect whether it is set up, and not for the others' do
      upsert_installation_config('FB_APP_ID', '1')
      upsert_installation_config('FB_APP_SECRET', 's')
      get '/super_admin/settings'

      expect(text(rows['facebook'].at_css('[data-testid="page-status"]'))).to eq('Настроено')
      expect(text(rows['tiktok'].at_css('[data-testid="page-status"]'))).to eq('Не настроено')
      expect(rows['general'].at_css('[data-testid="page-status"]')).to be_nil
      expect(rows['custom_branding'].at_css('[data-testid="page-status"]')).to be_nil
    end

    it 'says whether the AI models are set up by the key of OpenRouter' do
      allow(Llm::Config).to receive(:installation_provider_available?).with('openrouter').and_return(true)
      get '/super_admin/settings'

      expect(text(rows['captain'].at_css('[data-testid="page-status"]'))).to eq('Настроено')
      expect(rows['captain'].at_css('a')['href']).to eq('/super_admin/app_config?config=captain')
    end

    it 'is no showcase: no card of a function with «Недоступна», no function of the platform that has no page' do
      get '/super_admin/settings'

      expect(page.css('[data-feature]')).to be_empty
      expect(text(page.at_css('main'))).not_to match(/Недоступна|Журнал аудита|Отключение копирайта|Лимиты операторов/)
    end

    it 'does not list the branding where the function is not available, and does not link a page that is not found' do
      allow(ChatwootHub).to receive(:pricing_plan).and_return('community')
      get '/super_admin/settings'

      expect(rows.keys).not_to include('custom_branding')
      expect(page.css('a').pluck('href')).not_to include('/super_admin/app_config?config=custom_branding')
    end

    it 'has the version of OneLink as a small line at the bottom, with the whole build' do
      get '/super_admin/settings'

      footer = page.at_css('[data-testid="installation-block"]')
      expect(text(footer.at_css('[data-testid="onelink-version"]'))).to eq(SuperAdmin::BuildInfo.version)
      expect(text(footer)).to start_with('Версия OneLink:')
      expect(text(footer.at_css('[data-testid="onelink-build"]'))).to eq(SuperAdmin::BuildInfo.build) if SuperAdmin::BuildInfo.known?
    end

    it 'does not say «не определена» twice when the build does not know its commit' do
      stub_const('GIT_HASH', 'unknown')
      get '/super_admin/settings'

      expect(text(page.at_css('[data-testid="installation-block"]'))).to eq('Версия OneLink: не определена')
      expect(page.at_css('[data-testid="onelink-build"]')).to be_nil
    end

    it 'does not show the identifier the installation has at the hub of the base' do
      get '/super_admin/settings'

      expect(response.body).not_to include(ChatwootHub.installation_identifier)
      expect(response.body).not_to match(/тариф выше|Enterprise|sales@|Перейти на|upgrade/i)
    end
  end

  it 'shows the version of the build at the bottom of the menu of every page' do
    get '/super_admin/settings'

    version = page.at_css('nav [data-testid="nav-version"]')
    expect(text(version)).to eq("Версия #{SuperAdmin::BuildInfo.version}")
    expect(version['title']).to eq(SuperAdmin::BuildInfo.build)
  end
end
