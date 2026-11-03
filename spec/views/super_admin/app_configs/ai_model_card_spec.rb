# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'super_admin/app_configs/_ai_model_card' do
  let(:key) { 'CAPTAIN_MODERATION_MODEL' }
  let(:definitions) { ConfigLoader.new.general_configs.to_h { |config| [config['name'], config.except('name')] } }
  let(:page) do
    SuperAdmin::AiModelsPage.new(keys: [key], values: {}, definitions: definitions, masked_keys: [],
                                 options: SuperAdmin::AiModelOptions.new(recommended: Llm::Models::DEFAULT_CURATED_MODELS))
  end

  { ru: 'Не настроено', en: 'Not configured', kk: 'Бапталмаған' }.each do |locale, label|
    it "renders unconfigured moderation and its save description consistently in #{locale}" do
      I18n.with_locale(locale) do
        rendered = SuperAdmin::AppConfigsController.render(partial: 'super_admin/app_configs/ai_model_card', locals: { slot: page.slot(key) })
        html = Nokogiri::HTML.fragment(rendered)
        change = SuperAdmin::AiModelsForm::Change.new(key: key, old: 'test/previous-moderator', new: '', secret: false)

        expect(html.at_css('option[value=""]').text.squish).to eq(label)
        expect(html.at_css('[data-testid="slot-status"]').text.squish).to eq(label)
        expect(SuperAdmin::AiModelsChangeText.new(change).to_s).to end_with("→ #{label}")
      end
    end
  end
end
