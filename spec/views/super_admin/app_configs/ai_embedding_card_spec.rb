require 'rails_helper'

# The card of the embedding model on the «Модели ИИ» page only shows the model: it has no select and no tick, because vectors of two
# models cannot be compared and the model changes only with the full re-embedding (rake onelink:embeddings:apply). The partial is
# rendered alone: the page around it needs the compiled front-end assets.
RSpec.describe 'super_admin/app_configs/_ai_embedding_card' do
  let(:keys) { SuperAdmin::AppConfigsController::CAPTAIN_CONFIG_KEYS }
  let(:masked_keys) { SuperAdmin::AppConfigsController::MASKED_SECRET_CONFIG_KEYS }
  let(:definitions) { ConfigLoader.new.general_configs.to_h { |config| [config['name'], config.except('name')] } }
  let(:values) { { 'CAPTAIN_EMBEDDING_MODEL' => 'text-embedding-3-large' } }
  let(:submitted) { {} }
  let(:errors) { {} }
  let(:page) do
    SuperAdmin::AiModelsPage.new(keys: keys, values: values, definitions: definitions, masked_keys: masked_keys, submitted: submitted,
                                 errors: errors, options: SuperAdmin::AiModelOptions.new(recommended: Llm::Models::DEFAULT_CURATED_MODELS))
  end
  let(:html) do
    slot = page.slot('CAPTAIN_EMBEDDING_MODEL')
    Nokogiri::HTML.fragment(SuperAdmin::AppConfigsController.render(partial: 'super_admin/app_configs/ai_embedding_card', locals: { slot: slot }))
  end

  it 'shows the model in force and how it is changed, and offers nothing to change it with' do
    card = html.at_css('[data-config="CAPTAIN_EMBEDDING_MODEL"]')

    expect(card).to be_present
    expect(card.css('select, input, textarea, button')).to be_empty
    expect(html.to_s).not_to include('confirm_embedding_change')
    expect(card.at_css('.admin-notice').text).to include('rake onelink:embeddings:apply', 'только показана')
    expect(card.at_css('[data-testid="slot-status"]').text.squish).to include('text-embedding-3-large')
    expect(card.at_css('.admin-slot__title').text.squish).to eq('Поиск по базе знаний (индексация)')
  end

  it 'says that the built-in model is in force when the setting was never set' do
    page = SuperAdmin::AiModelsPage.new(keys: keys, values: {}, definitions: definitions, masked_keys: masked_keys,
                                        options: SuperAdmin::AiModelOptions.new(recommended: Llm::Models::DEFAULT_CURATED_MODELS))
    rendered = SuperAdmin::AppConfigsController.render(partial: 'super_admin/app_configs/ai_embedding_card',
                                                       locals: { slot: page.slot('CAPTAIN_EMBEDDING_MODEL') })

    expect(Nokogiri::HTML.fragment(rendered).at_css('[data-testid="slot-status"]').text.squish).to include('Gemini Embedding 001')
  end

  context 'when a request tried to change the model' do
    let(:submitted) { { 'CAPTAIN_EMBEDDING_MODEL' => 'google/gemini-embedding-001' } }
    let(:errors) { { 'CAPTAIN_EMBEDDING_MODEL' => ['модель меняется командой'] } }

    it 'shows why it was not changed' do
      expect(html.at_css('[data-error-for="CAPTAIN_EMBEDDING_MODEL"]').text).to include('Модель меняется командой')
    end
  end
end
