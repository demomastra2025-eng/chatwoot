require 'rails_helper'

RSpec.describe SuperAdmin::AiModelsPage do
  let(:keys) { SuperAdmin::AppConfigsController::CAPTAIN_CONFIG_KEYS }
  let(:masked_keys) { SuperAdmin::AppConfigsController::MASKED_SECRET_CONFIG_KEYS }
  let(:definitions) { ConfigLoader.new.general_configs.to_h { |config| [config['name'], config.except('name')] } }
  let(:values) { {} }
  let(:page) { described_class.new(keys: keys, values: values, definitions: definitions, masked_keys: masked_keys) }

  def slot(key)
    page.groups.flat_map(&:slots).find { |candidate| candidate.key == key }
  end

  describe '#groups' do
    it 'arranges the settings by purpose, in the order of the page, with a Russian title' do
      expect(page.groups.map(&:key)).to eq(%w[agent safety knowledge voice images classifiers connection prompts])
      expect(page.groups.map(&:title)).to eq(
        ['Основная модель агентов', 'Модерация и защита', 'Поиск по базе знаний', 'Голос и расшифровка', 'Картинки',
         'Классификаторы и служебные модели', 'Подключение и лимиты', 'Системные промпты']
      )
    end

    it 'puts every setting of the page into exactly one card' do
      slots = page.groups.flat_map(&:slots).map(&:key)

      expect(slots).to match_array(keys)
      expect(slots.uniq).to eq(slots)
    end

    it 'keeps a setting that no group names, in «Прочее»' do
      page = described_class.new(keys: keys + ['CAPTAIN_NEW_SETTING'], values: {}, definitions: definitions, masked_keys: masked_keys)

      other = page.groups.last
      expect(other.title).to eq('Прочее')
      expect(other.slots.map(&:key)).to eq(['CAPTAIN_NEW_SETTING'])
      expect(other.slots.first.title).to eq('CAPTAIN_NEW_SETTING')
    end

    it 'leaves out a group none of whose settings is on the page' do
      page = described_class.new(keys: %w[CAPTAIN_EMBEDDING_MODEL], values: {}, definitions: definitions, masked_keys: masked_keys)

      expect(page.groups.map(&:key)).to eq(['knowledge'])
    end
  end

  describe 'a card' do
    it 'has the Russian title and description of installation_config.yml for a model slot' do
      card = slot('CAPTAIN_AUDIO_TRANSCRIPTION_MODEL')

      expect(card.title).to eq('Модель расшифровки голоса')
      expect(card.hint).to include('расшифровки голосовых сообщений')
    end

    it 'has a Russian title from the locale for the settings that have only an English one in installation_config.yml' do
      expect(slot('CAPTAIN_OPENROUTER_API_KEY').title).to eq('Ключ OpenRouter')
      expect(slot('ACCOUNT_CAPTAIN_TOKENS_LIMIT').title).to eq('Лимит токенов ИИ на клинику')
    end

    it 'says it is set when the platform stored a value, and then the stored value is in force' do
      values['CAPTAIN_DEFAULT_MODEL'] = 'openai/gpt-5.6-luna'

      card = slot('CAPTAIN_DEFAULT_MODEL')

      expect(card).to have_attributes(configured: true, value: 'openai/gpt-5.6-luna', default: Llm::Config::DEFAULT_MODEL)
      expect(card.effective).to eq('openai/gpt-5.6-luna')
      expect(card.effective_items).to eq(['openai/gpt-5.6-luna'])
      expect(card.default_items).to eq([Llm::Config::DEFAULT_MODEL])
    end

    it 'follows the built-in default while the slot is blank' do
      values['CAPTAIN_AUDIO_TRANSCRIPTION_MODEL'] = ''

      card = slot('CAPTAIN_AUDIO_TRANSCRIPTION_MODEL')

      expect(card.configured).to be(false)
      expect(card.effective).to eq('openai/gpt-4o-mini-transcribe')
      expect(card.default).to eq(Llm::Models.configured_default_model_for('audio_transcription'))
    end

    it 'follows the default model of the installation for the slots that have no model of their own' do
      values['CAPTAIN_DEFAULT_MODEL'] = 'openai/gpt-5.6-luna'

      %w[CAPTAIN_CUSTOMER_NOTICE_MODEL CAPTAIN_IMAGE_RECOGNITION_MODEL CAPTAIN_LABEL_SUGGESTION_MODEL].each do |key|
        expect(slot(key)).to have_attributes(default: 'openai/gpt-5.6-luna', default_note: :default_model), key
      end
      expect(slot('CAPTAIN_MODERATION_MODEL').default_note).to be_nil
    end

    it 'follows the built-in default model when the installation default is blank too' do
      expect(slot('CAPTAIN_IMAGE_RECOGNITION_MODEL').default).to eq(Llm::Config::DEFAULT_MODEL)
    end

    it 'has a built-in value for the endpoint and for the short list of models' do
      expect(slot('CAPTAIN_OPENROUTER_ENDPOINT').default).to eq(Llm::Config::OPENROUTER_DEFAULT_API_BASE)
      expect(slot('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST').default_items).to eq(Llm::Models::DEFAULT_CURATED_MODELS)
    end

    it 'reads a stored short list (JSON text) or a list as models' do
      {
        '["openai/gpt-6-luna", "openai/gpt-5.6-luna"]' => %w[openai/gpt-6-luna openai/gpt-5.6-luna],
        %w[openai/gpt-6-luna] => %w[openai/gpt-6-luna],
        'not json' => []
      }.each do |stored, models|
        page = described_class.new(keys: keys, values: { 'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST' => stored }, definitions: definitions,
                                   masked_keys: masked_keys)
        card = page.groups.flat_map(&:slots).find { |candidate| candidate.key == 'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST' }

        expect(card.effective_items).to eq(models), stored.inspect
      end
    end

    it 'has no value to show for a blank setting without a built-in one' do
      card = slot('CAPTAIN_FIRECRAWL_API_KEY')

      expect(card.effective_items).to eq([])
      expect(slot('ACCOUNT_CAPTAIN_TOKENS_LIMIT').effective_items).to eq([])
    end

    it 'keeps a limit of 0 as a limit' do
      values['ACCOUNT_CAPTAIN_TOKENS_LIMIT'] = 0

      expect(slot('ACCOUNT_CAPTAIN_TOKENS_LIMIT')).to have_attributes(configured: true, effective_items: ['0'])
    end
  end

  describe 'secrets' do
    it 'says that a masked secret is set without carrying it' do
      values['CAPTAIN_OPENROUTER_API_KEY'] = 'sk-secret-value'

      card = slot('CAPTAIN_OPENROUTER_API_KEY')

      expect(card).to have_attributes(editor: :secret, configured: true, value: nil)
      expect(card.effective_items).to eq([])
      expect(card.to_a.compact.map(&:to_s).join).not_to include('sk-secret-value')
    end

    it 'covers every masked key of the captain page' do
      masked = masked_keys & keys
      values.merge!(masked.index_with { |key| "value-of-#{key}" })

      masked.each do |key|
        expect(slot(key)).to have_attributes(value: nil, configured: true), key
      end
    end

    it 'says that a secret is not set when there is nothing stored' do
      expect(slot('CAPTAIN_FIRECRAWL_API_KEY')).to have_attributes(configured: false, value: nil)
    end
  end

  describe 'editors' do
    it 'picks the editor of each kind of setting' do
      expect(slot('CAPTAIN_DEFAULT_MODEL').editor).to eq(:text)
      expect(slot('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST').editor).to eq(:allowlist)
      expect(slot('CAPTAIN_SYSTEM_PROMPTS').editor).to eq(:prompts)
      expect(slot('CAPTAIN_AI_AGENT_SYSTEM_PROMPT').editor).to eq(:textarea)
      expect(slot('CAPTAIN_OPENROUTER_API_KEY').editor).to eq(:secret)
      expect(slot('ACCOUNT_CAPTAIN_TOKENS_LIMIT').editor).to eq(:number)
    end

    it 'gives the wide cards to the text areas, the short list and the prompts' do
      wide = page.groups.flat_map(&:slots).select(&:wide?).map(&:key)

      expect(wide).to match_array(
        %w[CAPTAIN_ASSISTANT_MODEL_ALLOWLIST CAPTAIN_SYSTEM_PROMPTS CAPTAIN_AI_AGENT_SYSTEM_PROMPT CAPTAIN_AI_ASSISTANT_SYSTEM_PROMPT]
      )
    end
  end
end
