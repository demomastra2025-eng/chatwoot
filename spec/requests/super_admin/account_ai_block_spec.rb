require 'rails_helper'

# The block «ИИ» of the card of an account: the model its agents answer with, how many agents are on, and the own key of OpenRouter.
RSpec.describe 'Super Admin account card, the AI block', type: :request do
  let(:super_admin) { create(:super_admin) }
  let(:account) { create(:account, name: 'Аккаунт Алатау') }
  let(:card_path) { "/super_admin/accounts/#{account.id}" }
  let(:platform_model) { 'openai/gpt-6-luna' }

  before do
    sign_in(super_admin, scope: :super_admin)
    allow(Llm::Config).to receive(:model_for).with(feature: 'assistant').and_return(platform_model)
    allow(Llm::Config).to receive(:model_for).with(feature: 'assistant', account: account).and_return(platform_model)
  end

  def page = Nokogiri::HTML(response.body)

  def text(node) = node.text.squish

  def block = page.at_css('[data-testid="ai-block"]')

  def row(name) = text(block.at_css("[data-ai-row='#{name}']"))

  it 'sits in the main column of the card after the limits' do
    get card_path

    main = page.at_css('.admin-card-layout').element_children.first
    testids = main.css('[data-testid]').map { |node| node['data-testid'] }
    expect(testids.index('usage-block')).to be < testids.index('ai-block')
    expect(testids.index('ai-block')).to be < testids.index('channels-block')
  end

  it 'says the model of the platform for an account that chose nothing' do
    get card_path

    expect(row('model')).to eq("Модель ИИ-агентов #{SuperAdmin::AiModelOptions.name_of(platform_model)} как у платформы")
  end

  it 'says the model the account chose, as its own' do
    allow(Llm::Config).to receive(:model_for).with(feature: 'assistant', account: account).and_return('openai/gpt-5.4')
    account.update_columns(settings: { 'captain_models' => { 'assistant' => 'openai/gpt-5.4' } }) # rubocop:disable Rails/SkipsModelValidations

    get card_path

    expect(row('model')).to include(SuperAdmin::AiModelOptions.name_of('openai/gpt-5.4'), 'выбрана аккаунтом')
  end

  it 'says that the model is unknown, not an error, when the AI of the platform has no key' do
    allow(Llm::Config).to receive(:model_for).and_return(nil)

    get card_path

    expect(response).to have_http_status(:ok)
    expect(row('model')).to include('не определена')
  end

  it 'counts the agents that are on' do
    create(:captain_assistant, account: account, active: true)
    create(:captain_assistant, account: account, active: true)
    create(:captain_assistant, account: account, active: false)

    get card_path

    expect(row('agents')).to eq('ИИ-агенты включено 2 из 3')
  end

  it 'says that there are no agents yet' do
    get card_path

    expect(row('agents')).to include('ещё не создано ни одного')
  end

  it 'says how many agents keep a model of their own, because the model of the platform does not reach them' do
    create(:captain_assistant, account: account).update_columns(config: { 'model' => 'openai/gpt-5.4' }) # rubocop:disable Rails/SkipsModelValidations

    get card_path

    expect(text(block.at_css('[data-testid="ai-own-agents"]'))).to eq('У 1 агента своя модель: смена модели на платформе его не затронет.')
  end

  describe 'the own key of OpenRouter' do
    it 'is not allowed and not connected by default, and the block says no more about it' do
      get card_path

      expect(row('own-key')).to eq('Разрешить свой ключ OpenRouter не разрешён ключ не подключён')
      expect(block.at_css('[data-testid="ai-key-unused"]')).to be_nil
      expect(block.at_css('[data-testid="ai-key-platform"]')).to be_nil
    end

    it 'is allowed with the key connected' do
      account.enable_features!('captain_openrouter_byok')
      create(:integrations_hook, account: account, app_id: 'openrouter', access_token: 'account-openrouter-key', settings: {})

      get card_path

      expect(row('own-key')).to eq('Разрешить свой ключ OpenRouter разрешён ключ подключён')
      expect(response.body).not_to include('account-openrouter-key')
    end

    it 'says that the agents work on the key of the platform while the key is not connected' do
      account.enable_features!('captain_openrouter_byok')

      get card_path

      expect(row('own-key')).to eq('Разрешить свой ключ OpenRouter разрешён ключ не подключён')
      expect(text(block.at_css('[data-testid="ai-key-platform"]'))).to include('пока агенты работают на ключе платформы')
    end

    it 'says that a connected key is not used while it is not allowed' do
      create(:integrations_hook, account: account, app_id: 'openrouter', access_token: 'account-openrouter-key', settings: {})

      get card_path

      expect(row('own-key')).to eq('Разрешить свой ключ OpenRouter не разрешён ключ подключён')
      expect(text(block.at_css('[data-testid="ai-key-unused"]'))).to include('Ключ подключён, но не используется')
    end

    it 'points to the switch in «Служебные», which the link opens' do
      get card_path

      link = block.at_css('a[data-open-details]')
      expect(link['href']).to eq('#service-flags')
      expect(page.at_css('details#service-flags')).to be_present
    end

    it 'calls the switch of «Служебные» by what it does, and says what the agents use meanwhile' do
      get card_path

      service = text(page.at_css('[data-testid="service-flags-block"]'))
      expect(service).to include('Разрешить свой ключ OpenRouter', 'Пока ключ не подключён, они работают на ключе платформы')
      expect(service).not_to include('Свой ключ OpenRouter у аккаунта')
    end
  end

  describe 'the tariff' do
    it 'says whether the AI agents are in the plan of the account' do
      get card_path
      expect(text(block.at_css('[data-testid="ai-module"]'))).to eq('ИИ-агентов нет в тарифе')

      account.enable_features!('captain_integration')
      get card_path
      expect(text(block.at_css('[data-testid="ai-module"]'))).to eq('ИИ-агенты в тарифе')
    end
  end

  it 'has no missing translations and no prices' do
    get card_path

    expect(block.to_s).not_to include('translation missing')
    expect(block.text).not_to match(/₸|тенге|\$/)
  end
end
