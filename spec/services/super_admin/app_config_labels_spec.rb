require 'rails_helper'

RSpec.describe SuperAdmin::AppConfigLabels do
  let(:definition) { { 'display_title' => 'Display title', 'description' => 'Display description' } }

  describe '.title and .hint' do
    it 'take the Russian text of the config name first' do
      expect(described_class.title('FB_APP_ID', definition)).to eq('Facebook: ID приложения')
      expect(described_class.hint('FB_APP_ID', definition)).to eq('Идентификатор приложения Meta для Messenger.')
    end

    it 'fall back to the display title and description of installation_config.yml' do
      expect(described_class.title('SOME_NEW_CONFIG', definition)).to eq('Display title')
      expect(described_class.hint('SOME_NEW_CONFIG', definition)).to eq('Display description')
    end

    it 'fall back to the name, and to no hint, for a config nobody described' do
      expect(described_class.title('SOME_NEW_CONFIG')).to eq('SOME_NEW_CONFIG')
      expect(described_class.title('SOME_NEW_CONFIG', {})).to eq('SOME_NEW_CONFIG')
      expect(described_class.hint('SOME_NEW_CONFIG')).to eq('')
    end
  end

  describe '.page_title' do
    it 'names the pages in Russian' do
      expect(described_class.page_title('captain')).to eq('Модели ИИ')
      expect(described_class.page_title('internal')).to eq('Служебные параметры')
      expect(described_class.page_title('general')).to eq('Общие параметры')
      expect(described_class.page_title('facebook')).to eq('Facebook & Messenger')
      expect(described_class.page_title('whatsapp_embedded')).to eq('WhatsApp Embedded')
    end

    it 'humanizes a page nobody named' do
      expect(described_class.page_title('some_new_page')).to eq('Some new page')
    end
  end

  describe 'every setting of every page' do
    let(:definitions) do
      ConfigLoader.new.general_configs.to_h { |config| [config['name'], config.except('name')] }
    end
    let(:enterprise_pages) do
      host = Object.new.extend(Enterprise::SuperAdmin::AppConfigsController)
      %i[custom_branding_options internal_config_options saml_config_options].flat_map { |name| host.send(name) }
    end
    let(:keys) do
      SuperAdmin::AppConfigsController::APP_CONFIG_MAPPING.values.flatten +
        SuperAdmin::AppConfigsController::DEFAULT_ALLOWED_CONFIGS + enterprise_pages
    end

    it 'has a title with Russian letters and a hint, from the locale or from installation_config.yml' do
      expect(keys.uniq.size).to be > 80

      keys.uniq.each do |key|
        expect(described_class.title(key, definitions[key])).to match(/\p{Cyrillic}/), "title of #{key}"
        expect(described_class.hint(key, definitions[key])).to be_present, "hint of #{key}"
      end
    end
  end
end
