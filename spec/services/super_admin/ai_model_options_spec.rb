require 'rails_helper'

RSpec.describe SuperAdmin::AiModelOptions do
  let(:recommended) { Llm::Models::DEFAULT_CURATED_MODELS }
  let(:options) { described_class.new(recommended: recommended) }

  def ids(choices)
    choices.groups.flat_map { |_title, list| list.map(&:id) }
  end

  describe '.price_text' do
    it 'writes the price of a million tokens in dollars, input and output' do
      expect(described_class.price_text(BigDecimal('0.15'), BigDecimal('0.6'))).to eq('вход $0,15 / выход $0,6 за 1 млн')
      expect(described_class.price_text(BigDecimal('1.25'), BigDecimal(10))).to eq('вход $1,25 / выход $10 за 1 млн')
      expect(described_class.price_text(BigDecimal('0.075'), BigDecimal('0.3'))).to eq('вход $0,075 / выход $0,3 за 1 млн')
    end

    it 'writes one price for a model that is paid for what it reads only (an embedding model)' do
      expect(described_class.price_text(BigDecimal('0.02'), BigDecimal(0))).to eq('$0,02 за 1 млн')
    end

    it 'says «бесплатно» and «цена не указана» in words' do
      expect(described_class.price_text(BigDecimal(0), BigDecimal(0))).to eq('бесплатно')
      expect(described_class.price_text(nil, nil)).to eq('цена не указана')
    end
  end

  describe '.provider_title' do
    it 'names the company that makes the model' do
      expect(described_class.provider_title('openai/gpt-6-luna')).to eq('OpenAI')
      expect(described_class.provider_title('anthropic/claude-haiku-5.5')).to eq('Anthropic')
      expect(described_class.provider_title('meta-llama/llama-4')).to eq('Meta')
      expect(described_class.provider_title('some-lab/model')).to eq('Some Lab')
      expect(described_class.provider_title('text-embedding-3-small')).to eq('Прочие')
    end
  end

  describe '.name_of' do
    it 'gives the readable name of the catalog, or the id when the platform does not know the model' do
      expect(described_class.name_of('openai/gpt-6-luna')).to eq('GPT-6 Luna')
      expect(described_class.name_of('vendor/gone')).to eq('vendor/gone')
      expect(described_class.name_of('')).to be_nil
      expect(described_class.name_of(nil)).to be_nil
    end
  end

  describe '#choices_for without a key of OpenRouter (the built-in models of the platform only)' do
    it 'offers the models that fit the function, and none of the legacy direct providers' do
      choices = options.choices_for('CAPTAIN_AUDIO_TRANSCRIPTION_MODEL', builtin: 'openai/gpt-4o-mini-transcribe')

      expect(ids(choices)).to include('openai/gpt-4o-mini-transcribe', 'openai/gpt-audio-mini')
      expect(ids(choices)).not_to include('whisper-1', 'gpt-4o-transcribe')
      expect(choices.builtin_name).to eq('GPT-4o Mini Transcribe')
    end

    it 'does not offer a model that does not fit the function' do
      choices = options.choices_for('CAPTAIN_AUDIO_TRANSCRIPTION_MODEL')

      expect(ids(choices)).not_to include('openai/gpt-6-luna')
    end

    it 'puts the recommended models first, in a group of their own, and the rest by company' do
      choices = options.choices_for('CAPTAIN_DEFAULT_MODEL')

      expect(choices.groups.first.first).to eq('Рекомендуемые')
      expect(choices.groups.first.last.map(&:id)).to start_with('openai/gpt-6-luna', 'openai/gpt-5.6-luna')
      expect(choices.groups.first.last).to all(have_attributes(recommended: true))
    end

    it 'says what a model can do' do
      luna = options.choices_for('CAPTAIN_DEFAULT_MODEL').groups.flat_map(&:last).find { |option| option.id == 'openai/gpt-6-luna' }

      expect(luna.badges).to eq(%w[картинки инструменты рассуждение])
      expect(luna.name).to eq('GPT-6 Luna')
      expect(luna.provider).to eq('OpenAI')
    end

    it 'writes the whole option as plain text for a list without a script' do
      luna = options.choices_for('CAPTAIN_DEFAULT_MODEL').groups.flat_map(&:last).find { |option| option.id == 'openai/gpt-6-luna' }

      expect(luna.label).to eq('GPT-6 Luna · цена не указана · картинки, инструменты, рассуждение')
    end

    it 'offers for the default model only what fits the agent, the editor and the copilot' do
      expect(options.candidates(%w[assistant editor copilot])).to eq(
        options.candidates(%w[assistant]) & options.candidates(%w[editor]) & options.candidates(%w[copilot])
      )
    end
  end

  describe '#choices_for with the key of OpenRouter and a loaded catalog' do
    let(:capabilities) { %w[text_input text_output structured_output tool_calling tool_choice image_input streaming] }

    def chat_config(name, prompt, completion)
      { 'provider' => 'openrouter', 'display_name' => name, 'type' => 'chat', 'capabilities' => capabilities,
        'pricing' => { 'prompt' => prompt, 'completion' => completion } }
    end

    before do
      upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', 'sk-test-key')
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'anthropic/claude-sonnet-4.6' => chat_config('Anthropic: Claude Sonnet 4.6', '0.000003', '0.000015'),
        'openai/gpt-5.4' => chat_config('OpenAI: GPT-5.4', '0.0000025', '0.00001'),
        'zeta-ai/zeta-1' => chat_config('Zeta: Zeta 1', '0', '0'),
        'alpha-ai/alpha-2' => chat_config('Alpha: Alpha 2', '0.00000015', '0.0000006'),
        'alpha-ai/alpha-1' => chat_config('Alpha: Alpha 1', '0.0000001', '0.0000004'),
        'vendor/no-price' => chat_config('Vendor: Without a price', nil, nil).except('pricing')
      )
    end

    def option(choices, id)
      choices.groups.flat_map(&:last).find { |candidate| candidate.id == id }
    end

    it 'offers the models of the catalog with the price of a million tokens' do
      choices = options.choices_for('CAPTAIN_DEFAULT_MODEL', builtin: Llm::Config::DEFAULT_MODEL)

      expect(option(choices, 'anthropic/claude-sonnet-4.6')).to have_attributes(price_in: 3, price_out: 15, provider: 'Anthropic',
                                                                                 price_text: 'вход $3 / выход $15 за 1 млн')
      expect(option(choices, 'alpha-ai/alpha-2').price_text).to eq('вход $0,15 / выход $0,6 за 1 млн')
      expect(option(choices, 'zeta-ai/zeta-1').price_text).to eq('бесплатно')
      expect(option(choices, 'vendor/no-price').price_text).to eq('цена не указана')
    end

    it 'shows the recommended models first and the rest under the company, companies in alphabetical order, models by name' do
      choices = options.choices_for('CAPTAIN_DEFAULT_MODEL')

      expect(choices.groups.map(&:first)).to eq(['Рекомендуемые', 'Alpha Ai', 'Anthropic', 'Vendor', 'Zeta Ai'])
      expect(choices.groups.first.last.map(&:id)).to eq(%w[openai/gpt-6-luna openai/gpt-5.6-luna openai/gpt-5.4])
      expect(choices.groups.find { |title, _| title == 'Alpha Ai' }.last.map(&:id)).to eq(%w[alpha-ai/alpha-1 alpha-ai/alpha-2])
    end

    it 'still offers a function only the models that fit it' do
      caps_without_tools = { 'provider' => 'openrouter', 'display_name' => 'Plain', 'type' => 'chat', 'capabilities' => %w[text_input text_output] }
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return('vendor/plain' => caps_without_tools)

      expect(ids(options.choices_for('CAPTAIN_DEFAULT_MODEL'))).not_to include('vendor/plain')
    end
  end

  describe 'a saved model that the list does not offer' do
    it 'comes back as the missing model, marked, and is never replaced by another' do
      choices = options.choices_for('CAPTAIN_IMAGE_RECOGNITION_MODEL', current: 'vendor/gone')

      expect(choices.missing).to have_attributes(id: 'vendor/gone', note: 'нет в каталоге')
      expect(choices.missing).to be_missing
      expect(ids(choices)).not_to include('vendor/gone')
    end

    it 'says «сейчас не подходит» for a model the catalog knows but the function cannot use' do
      choices = options.choices_for('CAPTAIN_AUDIO_TRANSCRIPTION_MODEL', current: 'openai/gpt-6-luna')

      expect(choices.missing).to have_attributes(id: 'openai/gpt-6-luna', note: 'сейчас не подходит для этой функции')
    end

    it 'has no missing model when the saved model is on the list, or nothing is saved' do
      expect(options.choices_for('CAPTAIN_DEFAULT_MODEL', current: 'openai/gpt-6-luna').missing).to be_nil
      expect(options.choices_for('CAPTAIN_DEFAULT_MODEL', current: '').missing).to be_nil
      expect(options.choices_for('CAPTAIN_DEFAULT_MODEL', current: nil).missing).to be_nil
    end

    it 'describes a model the list does not offer with its mark' do
      expect(options.describe('vendor/gone', key: 'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST')).to have_attributes(id: 'vendor/gone', note: 'нет в каталоге')
      expect(options.describe('openai/gpt-6-luna', key: 'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST').note).to be_nil
    end
  end

  describe 'a setting that has no list of models' do
    it 'has an empty list' do
      choices = options.choices_for('CAPTAIN_OPENROUTER_ENDPOINT')

      expect(choices.groups).to eq([])
      expect(choices.builtin_name).to be_nil
    end
  end
end
