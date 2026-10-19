# frozen_string_literal: true

require 'rails_helper'

# The «Модели ИИ» page as a person uses it: every model is picked from a list, the whole form is posted at once and saved
# all or nothing, a saved model the catalog lost is kept, a change can be put back from the audit log. The form is posted
# the way a browser without scripts posts it (every control of the form, as drawn), so what is tested is the page itself.
RSpec.describe 'Super admin AI models page', type: :request do
  let(:super_admin) { create(:super_admin, name: 'Айдар') }
  let(:page) { Nokogiri::HTML(response.body) }
  let(:url) { '/super_admin/app_config?config=captain' }

  before do
    allow(ChatwootHub).to receive(:pricing_plan).and_return('enterprise')
    sign_in(super_admin, scope: :super_admin)
  end

  def text(node)
    node.text.squish
  end

  def card(key)
    page.at_css(%([data-testid="ai-models-form"] [data-config~="#{key}"]))
  end

  def stored(name)
    InstallationConfig.find_by(name: name)&.value
  end

  def refused(key)
    page.at_css(%([data-error-for="#{key}"]))&.text.to_s.squish
  end

  # The fields of the form as a browser sends them: [[name, value], ...]
  def form_pairs
    page.css('form#ai-models-form input, form#ai-models-form select, form#ai-models-form textarea').filter_map do |field|
      next if field['name'].blank? || field['disabled'] || %w[submit button image].include?(field['type'])

      case field.name
      when 'select' then [field['name'], (field.at_css('option[selected]') || field.at_css('option'))&.[]('value').to_s]
      when 'textarea' then [field['name'], field.text]
      else
        next if %w[checkbox radio].include?(field['type']) && field['checked'].nil?

        [field['name'], field['value'] || (field['type'] == 'checkbox' ? 'on' : '')]
      end
    end
  end

  # Post the form with some of its controls replaced: { 'app_config[KEY]' => 'value' } or an Array for a list
  def submit_form(replace = {})
    pairs = form_pairs.reject { |name, _| replace.key?(name) }
    replace.each { |name, value| Array(value).each { |item| pairs << [name, item] } }
    post url, params: URI.encode_www_form(pairs), headers: { 'CONTENT_TYPE' => 'application/x-www-form-urlencoded' }
  end

  def open_page
    get url
    expect(response).to have_http_status(:ok)
  end

  describe 'a list of models' do
    before { open_page }

    it 'is a plain select with «Встроенная» first, never a field to type a model into' do
      %w[CAPTAIN_MODERATION_MODEL CAPTAIN_CUSTOM_GUARDRAIL_MODEL CAPTAIN_AUDIO_TRANSCRIPTION_MODEL CAPTAIN_IMAGE_RECOGNITION_MODEL
         CAPTAIN_OUTCOME_CLASSIFIER_MODEL CAPTAIN_LANGUAGE_DETECTION_MODEL CAPTAIN_LABEL_SUGGESTION_MODEL CAPTAIN_CUSTOMER_NOTICE_MODEL
         CAPTAIN_EMBEDDING_MODEL].each do |key|
        select = page.at_css(%(select[name="app_config[#{key}]"]))

        expect(select).to be_present, key
        expect(select.at_css('option')['value']).to eq(''), key
        expect(text(select.at_css('option'))).to start_with('Встроенная: '), key
        expect(page.css(%(input[name="app_config[#{key}]"]))).to be_empty, key
      end
    end

    it 'offers only the models that fit the function, grouped by company with the recommended first' do
      select = page.at_css('select[name="app_config[CAPTAIN_AUDIO_TRANSCRIPTION_MODEL]"]')
      values = select.css('option').pluck('value')

      expect(values).to include('', 'openai/gpt-4o-mini-transcribe', 'openai/gpt-audio-mini')
      expect(values).not_to include('openai/gpt-6-luna', 'whisper-1')
      expect(select.css('optgroup').pluck('label')).to all(be_present)
    end

    it 'writes the name and the badges of a model in the option, and gives the script what it needs to draw it' do
      option = page.at_css('select[name="app_config[CAPTAIN_IMAGE_RECOGNITION_MODEL]"] option[value="openai/gpt-6-luna"]')

      expect(text(option)).to eq('GPT-6 Luna · цена не указана · картинки, инструменты, рассуждение')
      expect(option['data-name']).to eq('GPT-6 Luna')
      expect(option['data-badges']).to eq('картинки,инструменты,рассуждение')
      expect(option['data-provider']).to eq('OpenAI')
    end

    it 'offers the model of the platform as the first choice of the default model of the agents' do
      expect(text(card('CAPTAIN_DEFAULT_MODEL').at_css('[data-row-platform]'))).to include('Как у платформы: GPT-6 Luna')
    end
  end

  describe 'with the key of OpenRouter and a loaded catalog' do
    let(:capabilities) { %w[text_input text_output structured_output tool_calling tool_choice image_input streaming reasoning] }

    before do
      upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', 'sk-test-key')
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'anthropic/claude-sonnet-4.6' => { 'provider' => 'openrouter', 'display_name' => 'Anthropic: Claude Sonnet 4.6', 'type' => 'chat',
                                           'capabilities' => capabilities, 'pricing' => { 'prompt' => '0.000003', 'completion' => '0.000015' } }
      )
      open_page
    end

    it 'shows the price of a million tokens in and out, and the badges, in the list of the default model' do
      option = page.at_css('select[name="app_config[CAPTAIN_ASSISTANT_MODEL_ALLOWLIST][]"] option[value="anthropic/claude-sonnet-4.6"]')

      expect(text(option)).to eq('Anthropic: Claude Sonnet 4.6 · вход $3 / выход $15 за 1 млн · картинки, инструменты, рассуждение')
      expect(option.parent['label']).to eq('Anthropic')
    end

    it 'adds a model to the short list from the list «Добавить другую модель», which posts into the same list' do
      add = card('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST').at_css('select[data-allowlist-add]')

      expect(add['name']).to eq('app_config[CAPTAIN_ASSISTANT_MODEL_ALLOWLIST][]')
      expect(text(add.at_css('option'))).to eq('Выберите модель…')
    end
  end

  describe 'posting the whole form without changing anything' do
    it 'saves nothing and says so' do
      open_page

      expect { submit_form }.not_to(change { [InstallationConfig.count, Audited::Audit.count] })

      expect(response).to redirect_to(super_admin_app_config_path(config: 'captain'))
      expect(flash[:notice]).to eq('Ничего не изменилось: все значения такие же, как были.')
    end

    it 'does not pin the recommended list or the built-in models, which are only shown' do
      InstallationConfig.where(name: %w[CAPTAIN_ASSISTANT_MODEL_ALLOWLIST CAPTAIN_AUDIO_TRANSCRIPTION_MODEL CAPTAIN_SYSTEM_PROMPTS]).delete_all
      open_page
      submit_form

      expect(InstallationConfig.where(name: %w[CAPTAIN_ASSISTANT_MODEL_ALLOWLIST CAPTAIN_AUDIO_TRANSCRIPTION_MODEL CAPTAIN_SYSTEM_PROMPTS])).to be_empty
      expect(Audited::Audit.where(action: SuperAdmin::AppConfigSaver::AUDIT_ACTION)).to be_empty
    end
  end

  describe 'a model that was saved and is not in the catalog (any more)' do
    before do
      upsert_installation_config('CAPTAIN_IMAGE_RECOGNITION_MODEL', 'vendor/gone')
      open_page
    end

    it 'stays selected, marked «нет в каталоге», and the card says what to do' do
      selected = card('CAPTAIN_IMAGE_RECOGNITION_MODEL').at_css('select option[selected]')

      expect(selected['value']).to eq('vendor/gone')
      expect(text(selected)).to eq('vendor/gone · нет в каталоге')
      expect(text(card('CAPTAIN_IMAGE_RECOGNITION_MODEL').at_css('[data-testid="slot-missing"]')))
        .to eq('Эта модель сохранена, но её нет в каталоге. Она останется выбранной, пока вы не выберете другую.')
      expect(text(card('CAPTAIN_IMAGE_RECOGNITION_MODEL').at_css('[data-testid="slot-status"]'))).to include('Вы выбрали: vendor/gone')
    end

    it 'is not replaced when the form is saved for another setting' do
      submit_form('app_config[CAPTAIN_MODERATION_MODEL]' => 'openai/gpt-oss-safeguard-20b')

      expect(response).to redirect_to(super_admin_app_config_path(config: 'captain'))
      expect(stored('CAPTAIN_IMAGE_RECOGNITION_MODEL')).to eq('vendor/gone')
      expect(stored('CAPTAIN_MODERATION_MODEL')).to eq('openai/gpt-oss-safeguard-20b')
    end

    it 'is replaced only when the admin picks another model' do
      submit_form('app_config[CAPTAIN_IMAGE_RECOGNITION_MODEL]' => 'openai/gpt-5.6-luna')

      expect(stored('CAPTAIN_IMAGE_RECOGNITION_MODEL')).to eq('openai/gpt-5.6-luna')
    end

    it 'can be put back to the built-in model with the empty option' do
      submit_form('app_config[CAPTAIN_IMAGE_RECOGNITION_MODEL]' => '')

      expect(stored('CAPTAIN_IMAGE_RECOGNITION_MODEL').to_s).to eq('')
    end
  end

  describe 'a short list that holds a model the catalog lost' do
    before do
      upsert_installation_config('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST', '["openai/gpt-6-luna","vendor/gone"]')
      upsert_installation_config('CAPTAIN_DEFAULT_MODEL', 'openai/gpt-6-luna')
      open_page
    end

    it 'shows it ticked with its mark, so that it can be unticked' do
      row = card('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST').at_css('[data-model-id="vendor/gone"]')

      expect(row.at_css('input[type="checkbox"]')['checked']).to be_present
      expect(text(row)).to include('нет в каталоге')
    end

    it 'does not stop another change, and keeps the model while it stays ticked' do
      submit_form('app_config[CAPTAIN_MODERATION_MODEL]' => 'openai/gpt-oss-safeguard-20b')

      expect(response).to redirect_to(super_admin_app_config_path(config: 'captain'))
      expect(stored('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST')).to eq('["openai/gpt-6-luna","vendor/gone"]')
    end

    it 'drops the model when it is unticked' do
      submit_form('app_config[CAPTAIN_ASSISTANT_MODEL_ALLOWLIST][]' => ['', 'openai/gpt-6-luna'])

      expect(stored('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST')).to eq('["openai/gpt-6-luna"]')
    end
  end

  describe 'saving' do
    before do
      upsert_installation_config('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST', '["openai/gpt-6-luna"]')
      upsert_installation_config('CAPTAIN_DEFAULT_MODEL', 'openai/gpt-6-luna')
      open_page
    end

    it 'adds a model to the list and makes it the default in one step, and lists what changed' do
      submit_form('app_config[CAPTAIN_ASSISTANT_MODEL_ALLOWLIST][]' => ['', 'openai/gpt-6-luna', 'openai/gpt-5.6-luna'],
                  'app_config[CAPTAIN_DEFAULT_MODEL]' => 'openai/gpt-5.6-luna')

      expect(response).to redirect_to(super_admin_app_config_path(config: 'captain'))
      expect(stored('CAPTAIN_DEFAULT_MODEL')).to eq('openai/gpt-5.6-luna')
      expect(JSON.parse(stored('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST'))).to eq(%w[openai/gpt-6-luna openai/gpt-5.6-luna])
      expect(flash[:notice]).to eq('Сохранено. Изменено: Модель по умолчанию: GPT-6 Luna → GPT-5.6 Luna; Короткий список моделей: 1 → 2')
    end

    it 'writes one entry of the audit log for each setting that changed, with the name of the admin' do
      submit_form('app_config[CAPTAIN_MODERATION_MODEL]' => 'openai/gpt-oss-safeguard-20b', 'app_config[ACCOUNT_CAPTAIN_TOKENS_LIMIT]' => '1 000')

      audits = Audited::Audit.where(action: SuperAdmin::AppConfigSaver::AUDIT_ACTION)
      expect(audits.map { |audit| audit.audited_changes['name'] }).to contain_exactly('CAPTAIN_MODERATION_MODEL', 'ACCOUNT_CAPTAIN_TOKENS_LIMIT')
      expect(audits).to all(have_attributes(user_id: super_admin.id, comment: 'super_admin'))
    end

    it 'saves nothing when one value is refused, shows the page again with every value as it was sent, and says what is wrong in the card' do
      submit_form('app_config[CAPTAIN_MODERATION_MODEL]' => 'openai/gpt-oss-safeguard-20b', 'app_config[CAPTAIN_IMAGE_RECOGNITION_MODEL]' => 'vendor/typo',
                  'app_config[ACCOUNT_CAPTAIN_TOKENS_LIMIT]' => '2 млн')

      expect(response).to have_http_status(:unprocessable_entity)
      expect(stored('CAPTAIN_MODERATION_MODEL')).not_to eq('openai/gpt-oss-safeguard-20b')
      expect(Audited::Audit.where(action: SuperAdmin::AppConfigSaver::AUDIT_ACTION)).to be_empty
      expect(text(page.at_css('.flash-alert'))).to eq('Ничего не сохранено: исправьте 2 настройки, они отмечены красным.')
      expect(refused('CAPTAIN_IMAGE_RECOGNITION_MODEL')).to include('vendor/typo', 'не найдена в каталоге')
      expect(refused('ACCOUNT_CAPTAIN_TOKENS_LIMIT')).to eq('Введите целое число без букв или оставьте поле пустым.')
      # what was entered is still in the controls
      expect(card('CAPTAIN_IMAGE_RECOGNITION_MODEL').at_css('select option[selected]')['value']).to eq('vendor/typo')
      expect(card('CAPTAIN_MODERATION_MODEL').at_css('select option[selected]')['value']).to eq('openai/gpt-oss-safeguard-20b')
      expect(card('ACCOUNT_CAPTAIN_TOKENS_LIMIT').at_css('input')['value']).to eq('2 млн')
    end

    it 'marks the cards that were refused, so that the script opens their tab and keeps the bar of changes on' do
      submit_form('app_config[CAPTAIN_IMAGE_RECOGNITION_MODEL]' => 'vendor/typo')

      expect(card('CAPTAIN_IMAGE_RECOGNITION_MODEL')['class']).to include('admin-slot--invalid')
      expect(page.at_css('[data-ai-models]')['data-unsaved-keys'].split).to include('CAPTAIN_IMAGE_RECOGNITION_MODEL')
      expect(page.at_css('form#ai-models-form')['data-cancel-url']).to eq('/super_admin/app_config?config=captain')
    end

    it 'refuses a default model that the list saved with it does not hold, in the card of the agent' do
      submit_form('app_config[CAPTAIN_DEFAULT_MODEL]' => 'openai/gpt-5.6-luna')

      expect(response).to have_http_status(:unprocessable_entity)
      expect(refused('CAPTAIN_DEFAULT_MODEL')).to include('должна быть в коротком списке')
      expect(stored('CAPTAIN_DEFAULT_MODEL')).to eq('openai/gpt-6-luna')
    end

    it 'does not print a secret that was typed into a form that was refused' do
      submit_form('app_config[CAPTAIN_FIRECRAWL_API_KEY]' => 'fc-typed-secret', 'app_config[CAPTAIN_IMAGE_RECOGNITION_MODEL]' => 'vendor/typo')

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).not_to include('fc-typed-secret')
      expect(stored('CAPTAIN_FIRECRAWL_API_KEY')).not_to eq('fc-typed-secret')
    end
  end

  describe 'putting a value back' do
    before do
      upsert_installation_config('CAPTAIN_DEFAULT_MODEL', 'openai/gpt-6-luna')
      upsert_installation_config('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST', '["openai/gpt-6-luna","openai/gpt-5.6-luna"]')
      open_page
      submit_form('app_config[CAPTAIN_DEFAULT_MODEL]' => 'openai/gpt-5.6-luna')
      open_page
    end

    def revert_button(key)
      page.css(%(button[data-revert="#{key}"])).find { |button| button['data-revert-value'].present? }
    end

    it 'says what the model was, who changed it and when, from the audit log' do
      history = page.at_css('[data-testid="slot-history"][data-history-for="CAPTAIN_DEFAULT_MODEL"]')

      expect(text(history)).to match(/Модель по умолчанию\. Было: GPT-6 Luna, изменил Айдар \d\d\.\d\d\.\d{4} \d\d:\d\d Вернуть/)
      expect(revert_button('CAPTAIN_DEFAULT_MODEL')['data-revert-value']).to eq('openai/gpt-6-luna')
    end

    it 'offers «Вернуть встроенную» next to the model that was chosen' do
      status = card('CAPTAIN_DEFAULT_MODEL').at_css('[data-testid="slot-status"]')

      expect(text(status)).to include('Вы выбрали: GPT-5.6 Luna', 'Вернуть встроенную')
      expect(status.at_css('button[data-revert="CAPTAIN_DEFAULT_MODEL"]')['data-revert-value']).to eq('')
    end

    it 'puts the earlier model back with an ordinary save, which is written to the audit log like any other' do
      earlier = revert_button('CAPTAIN_DEFAULT_MODEL')['data-revert-value']

      submit_form('app_config[CAPTAIN_DEFAULT_MODEL]' => earlier)
      open_page

      expect(stored('CAPTAIN_DEFAULT_MODEL')).to eq('openai/gpt-6-luna')
      expect(Audited::Audit.where(action: SuperAdmin::AppConfigSaver::AUDIT_ACTION).count).to eq(2)
      expect(text(page.at_css('[data-testid="slot-history"][data-history-for="CAPTAIN_DEFAULT_MODEL"]'))).to include('Было: GPT-5.6 Luna')
    end

    it 'puts the built-in model back with the empty value' do
      submit_form('app_config[CAPTAIN_DEFAULT_MODEL]' => '')
      open_page

      expect(stored('CAPTAIN_DEFAULT_MODEL').to_s).to eq('')
      expect(text(card('CAPTAIN_DEFAULT_MODEL').at_css('[data-testid="slot-status"]'))).to include('Используется встроенная: GPT-6 Luna')
    end

    it 'puts an earlier short list back, whole' do
      submit_form('app_config[CAPTAIN_ASSISTANT_MODEL_ALLOWLIST][]' => ['', 'openai/gpt-6-luna'], 'app_config[CAPTAIN_DEFAULT_MODEL]' => 'openai/gpt-6-luna')
      open_page
      earlier = page.at_css('button[data-revert="CAPTAIN_ASSISTANT_MODEL_ALLOWLIST"]')

      expect(JSON.parse(earlier['data-revert-value'])).to eq(%w[openai/gpt-6-luna openai/gpt-5.6-luna])
      expect(text(card('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST').at_css('[data-history-for="CAPTAIN_ASSISTANT_MODEL_ALLOWLIST"]'))).to include('Было: 2 модели')
    end

    it 'offers nothing for a setting that was changed by other means since' do
      upsert_installation_config('CAPTAIN_DEFAULT_MODEL', 'openai/gpt-5.6-luna ')
      open_page

      expect(page.at_css('[data-history-for="CAPTAIN_DEFAULT_MODEL"]')).to be_nil
    end
  end

  describe 'the model of the knowledge base search' do
    before do
      upsert_installation_config('CAPTAIN_EMBEDDING_MODEL', 'vendor/old-embedding')
      open_page
    end

    it 'is under «Для разработчика», in a folded block, with a warning, and not on a tab' do
      developer = page.at_css('details#ai-developer')

      expect(developer['open']).to be_nil
      expect(developer.at_css('select[name="app_config[CAPTAIN_EMBEDDING_MODEL]"]')).to be_present
      expect(page.at_css('[data-tab-panel] select[name="app_config[CAPTAIN_EMBEDDING_MODEL]"]')).to be_nil
      expect(text(developer.at_css('[data-config="CAPTAIN_EMBEDDING_MODEL"] .admin-notice')))
        .to include('поиск по базам знаний и FAQ всех аккаунтов станет хуже', 'Переиндексацию эта страница не запускает')
    end

    it 'is not changed without the tick, and the block opens to show why' do
      submit_form('app_config[CAPTAIN_EMBEDDING_MODEL]' => '')

      expect(response).to have_http_status(:unprocessable_entity)
      expect(stored('CAPTAIN_EMBEDDING_MODEL')).to eq('vendor/old-embedding')
      expect(refused('CAPTAIN_EMBEDDING_MODEL')).to include('Я понимаю последствия')
      expect(page.at_css('details#ai-developer')['open']).to be_present
    end

    it 'is changed with the tick' do
      submit_form('app_config[CAPTAIN_EMBEDDING_MODEL]' => '', 'confirm_embedding_change' => '1')

      expect(response).to redirect_to(super_admin_app_config_path(config: 'captain'))
      expect(stored('CAPTAIN_EMBEDDING_MODEL').to_s).to eq('')
    end

    it 'is not asked for when another setting is saved and the model is left as it is' do
      submit_form('app_config[CAPTAIN_MODERATION_MODEL]' => 'openai/gpt-oss-safeguard-20b')

      expect(response).to redirect_to(super_admin_app_config_path(config: 'captain'))
      expect(stored('CAPTAIN_EMBEDDING_MODEL')).to eq('vendor/old-embedding')
    end
  end

  describe 'the rules of the platform' do
    before { open_page }

    it 'are drawn from the saved rules, with the group and the place chosen from lists in Russian' do
      builder = page.at_css('[data-prompts-builder]')
      template = builder.at_css('template')

      expect(JSON.parse(builder['data-initial-prompts']).pluck('id')).to include('stay_within_scope', 'assistant_identity')
      expect(template.css('[data-field="group"] option').map { |option| text(option) })
        .to eq(['Строгие правила', 'Ход разговора', 'Ограничения', 'Устройство агента', 'Устройство сценария', 'Контекст диалога'])
      expect(template.css('[data-field="slot"] option').map { |option| text(option) }.first(2)).to eq(['Обычное правило', 'Агент: общий контекст'])
      expect(template.css('input[type="text"]')).to be_empty
    end

    it 'are deleted only after a question' do
      template = page.at_css('[data-prompts-builder] template')

      expect(text(template.at_css('[data-role="confirm"]'))).to include('Удалить это правило?', 'Да, удалить', 'Отмена')
      expect(template.at_css('[data-role="confirm"]')['hidden']).to be_present
    end

    it 'are saved from the field of the builder, and a group or a place typed by hand is refused' do
      rule = { id: 'new_rule', type: 'system', group: 'Strict rules', content: 'Answer briefly.', slot: nil }

      submit_form('app_config[CAPTAIN_SYSTEM_PROMPTS]' => [rule].to_json)
      expect(response).to redirect_to(super_admin_app_config_path(config: 'captain'))
      expect(stored('CAPTAIN_SYSTEM_PROMPTS')).to eq([rule.stringify_keys])

      open_page
      submit_form('app_config[CAPTAIN_SYSTEM_PROMPTS]' => [rule.merge(group: 'Строгие правила (моя)')].to_json)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(refused('CAPTAIN_SYSTEM_PROMPTS')).to eq('Правило 1: группа «Строгие правила (моя)» не из списка. Выберите группу из списка.')
    end
  end

  describe 'the shell of the page' do
    before { open_page }

    it 'has the sticky bar of changes, hidden until something changes, and a plain save button for a page without a script' do
      bar = page.at_css('form#ai-models-form [data-savebar]')

      expect(bar['hidden']).to be_present
      expect(text(bar)).to include('Отменить', 'Сохранить')
      expect(page.at_css('form#ai-models-form [data-static-save] input[type="submit"]')['value']).to eq('Сохранить настройки')
    end

    it 'gives the script its texts, with the forms of a number in Russian' do
      texts = JSON.parse(page.at_css('[data-ai-models]')['data-texts'])

      expect(texts['changed']).to eq('one' => 'Изменена %{count} настройка', 'few' => 'Изменено %{count} настройки',
                                     'many' => 'Изменено %{count} настроек', 'other' => 'Изменено %{count} настройки')
      expect(texts['leave']).to include('несохранённые изменения')
      expect(texts['counter']).to eq('%{count} из %{max}')
    end

    it 'counts the models of the short list as «5 из 12»' do
      expect(text(card('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST').at_css('[data-counter]'))).to match(/\A\d+ из 12\z/)
    end
  end
end
