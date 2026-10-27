require 'rails_helper'

RSpec.describe SuperAdmin::AiModelsForm do
  let(:keys) { SuperAdmin::AppConfigsController::CAPTAIN_CONFIG_KEYS }
  let(:masked) { SuperAdmin::AppConfigsController::MASKED_SECRET_CONFIG_KEYS }
  let(:stored) { {} }
  let(:super_admin) { create(:super_admin) }

  # form('KEY' => 'value') or form({ 'KEY' => 'value' }, stored_values: { ... })
  def form(submitted = nil, stored_values: stored, **inline)
    described_class.new(submitted: submitted || inline, stored: stored_values, keys: keys, masked_keys: masked)
  end

  def changed(form_object)
    form_object.changes.to_h { |change| [change.key, change.new] }
  end

  describe 'a model of one function' do
    it 'records a model that fits and nothing else' do
      result = form('CAPTAIN_AUDIO_TRANSCRIPTION_MODEL' => 'openai/gpt-audio-mini')

      expect(result).to be_valid
      expect(changed(result)).to eq('CAPTAIN_AUDIO_TRANSCRIPTION_MODEL' => 'openai/gpt-audio-mini')
    end

    it 'refuses a model that is unknown or does not fit, and names it, in Russian' do
      result = form('CAPTAIN_AUDIO_TRANSCRIPTION_MODEL' => 'vendor/unknown', 'CAPTAIN_IMAGE_RECOGNITION_MODEL' => 'openai/gpt-4o-mini-transcribe')

      expect(result).not_to be_valid
      expect(result.errors).to include('CAPTAIN_AUDIO_TRANSCRIPTION_MODEL', 'CAPTAIN_IMAGE_RECOGNITION_MODEL')
      expect(result.errors.size).to eq(2)
      expect(result.errors['CAPTAIN_AUDIO_TRANSCRIPTION_MODEL'].first).to include('vendor/unknown', 'не найдена в каталоге')
    end

    it 'treats a blank value as «встроенная» and records the change from a model' do
      result = form({ 'CAPTAIN_AUDIO_TRANSCRIPTION_MODEL' => '' }, stored_values: { 'CAPTAIN_AUDIO_TRANSCRIPTION_MODEL' => 'openai/gpt-audio-mini' })

      expect(changed(result)).to eq('CAPTAIN_AUDIO_TRANSCRIPTION_MODEL' => '')
    end

    it 'does not touch a model that was not changed, even when the catalog has lost it' do
      stored_values = { 'CAPTAIN_IMAGE_RECOGNITION_MODEL' => 'vendor/gone', 'CAPTAIN_AUDIO_TRANSCRIPTION_MODEL' => '' }
      result = form({ 'CAPTAIN_IMAGE_RECOGNITION_MODEL' => 'vendor/gone', 'CAPTAIN_AUDIO_TRANSCRIPTION_MODEL' => 'openai/gpt-audio-mini' },
                    stored_values: stored_values)

      expect(result).to be_valid
      expect(changed(result)).to eq('CAPTAIN_AUDIO_TRANSCRIPTION_MODEL' => 'openai/gpt-audio-mini')
    end

    it 'refuses a lost model that is typed in anew' do
      expect(form('CAPTAIN_IMAGE_RECOGNITION_MODEL' => 'vendor/gone')).not_to be_valid
    end
  end

  describe 'the short list and the default model, together' do
    let(:stored) do
      { 'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST' => '["openai/gpt-6-luna"]', 'CAPTAIN_DEFAULT_MODEL' => 'openai/gpt-6-luna' }
    end

    it 'saves a model added to the list and made the default in one step' do
      result = form('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST' => %w[openai/gpt-6-luna openai/gpt-5.6-luna],
                    'CAPTAIN_DEFAULT_MODEL' => 'openai/gpt-5.6-luna')

      expect(result).to be_valid
      expect(changed(result)).to eq(
        'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST' => '["openai/gpt-6-luna","openai/gpt-5.6-luna"]', 'CAPTAIN_DEFAULT_MODEL' => 'openai/gpt-5.6-luna'
      )
    end

    it 'refuses a default model that is not on the list that is saved with it' do
      result = form('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST' => %w[openai/gpt-6-luna], 'CAPTAIN_DEFAULT_MODEL' => 'openai/gpt-5.6-luna')

      expect(result).not_to be_valid
      expect(result.errors['CAPTAIN_DEFAULT_MODEL'].first).to include('должна быть в коротком списке')
    end

    it 'refuses a default model that is not on the stored list when only the default is sent' do
      expect(form('CAPTAIN_DEFAULT_MODEL' => 'openai/gpt-5.6-luna')).not_to be_valid
    end

    it 'refuses a list without the default model that stays' do
      result = form('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST' => %w[openai/gpt-5.6-luna])

      expect(result).not_to be_valid
      expect(result.errors['CAPTAIN_ASSISTANT_MODEL_ALLOWLIST'].first).to include('openai/gpt-6-luna')
    end

    it 'checks a list that moves away from the platform default against the default of the platform' do
      result = form({ 'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST' => %w[openai/gpt-5.6-luna] }, stored_values: {})

      expect(result).not_to be_valid
      expect(result.errors['CAPTAIN_ASSISTANT_MODEL_ALLOWLIST'].first).to include(Llm::Config::DEFAULT_MODEL)
    end

    it 'accepts a list of two models and the platform default together' do
      result = form({ 'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST' => %w[openai/gpt-6-luna openai/gpt-5.6-luna], 'CAPTAIN_DEFAULT_MODEL' => '' },
                    stored_values: {})

      expect(result).to be_valid
    end

    it 'refuses more models than the limit' do
      models = Array.new(Llm::InstallationModelConfig::ALLOWLIST_LIMIT + 1) { |index| "vendor/model-#{index}" }

      expect(form('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST' => models).errors['CAPTAIN_ASSISTANT_MODEL_ALLOWLIST'].first).to include('не больше 12 моделей')
    end

    it 'does not read the empty tick of the form as a model' do
      result = form('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST' => ['', 'openai/gpt-6-luna', ''])

      expect(result).to be_valid
      expect(result.changes).to be_empty
    end

    it 'does not change the stored list when the same models are sent in another order' do
      result = form({ 'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST' => %w[openai/gpt-5.6-luna openai/gpt-6-luna] },
                    stored_values: stored.merge('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST' => '["openai/gpt-6-luna","openai/gpt-5.6-luna"]'))

      expect(result).to be_valid
      expect(result.changes).to be_empty
    end

    it 'keeps a stored model that the catalog lost when the list is changed, but not when it is added anew' do
      stored_values = stored.merge('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST' => '["openai/gpt-6-luna","vendor/gone"]')

      kept = form({ 'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST' => %w[openai/gpt-6-luna vendor/gone openai/gpt-5.6-luna] }, stored_values: stored_values)
      added = form({ 'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST' => %w[openai/gpt-6-luna vendor/other] }, stored_values: stored_values)

      expect(kept).to be_valid
      expect(added).not_to be_valid
    end

    it 'writes nothing while no list is saved and the recommended one is sent' do
      result = form({ 'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST' => Llm::Models::DEFAULT_CURATED_MODELS.dup }, stored_values: {})

      expect(result).to be_valid
      expect(result.changes).to be_empty
    end

    it 'saves the recommended models as a list when a list was saved before, never as a blank value' do
      result = form({ 'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST' => Llm::Models::DEFAULT_CURATED_MODELS.dup }, stored_values: stored)

      expect(changed(result)).to eq('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST' => JSON.generate(Llm::Models::DEFAULT_CURATED_MODELS))
    end

    it 'does not change a saved list that already holds the recommended models, in any order' do
      stored_values = { 'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST' => JSON.generate(Llm::Models::DEFAULT_CURATED_MODELS) }

      result = form({ 'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST' => Llm::Models::DEFAULT_CURATED_MODELS.reverse }, stored_values: stored_values)

      expect(result).to be_valid
      expect(result.changes).to be_empty
    end

    it 'refuses a checklist with nothing ticked while a list is saved, and says what to do' do
      result = form('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST' => [''])

      expect(result).not_to be_valid
      expect(result.errors['CAPTAIN_ASSISTANT_MODEL_ALLOWLIST']).to eq(['Отметьте хотя бы одну модель.'])
    end

    it 'does not block the page when nothing is ticked and no readable list is saved' do
      ['', '[]', '{broken'].each do |saved|
        result = form({ 'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST' => [''] }, stored_values: { 'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST' => saved })

        expect(result).to be_valid, saved
        expect(result.changes).to be_empty, saved
      end
    end

    it 'still clears the list with a blank text, as before' do
      result = form('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST' => '  ')

      expect(result).to be_valid
      expect(changed(result)).to eq('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST' => '')
    end

    it 'does not read the list sent as text of a wrong shape' do
      ['{not json', '{"a": 1}', '[1]'].each do |value|
        result = form('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST' => value)

        expect(result.errors['CAPTAIN_ASSISTANT_MODEL_ALLOWLIST'])
          .to eq(['Список моделей не распознан. Обновите страницу и отметьте модели ещё раз.']), value
      end
    end

    it 'accepts the list as the JSON text the page sent before' do
      result = form('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST' => '["openai/gpt-6-luna", " openai/gpt-5.6-luna "]')

      expect(changed(result)).to eq('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST' => '["openai/gpt-6-luna","openai/gpt-5.6-luna"]')
    end
  end

  describe 'the model of the knowledge base search' do
    it 'is not changed here: vectors of two models cannot be compared, so the model changes only with the full re-embedding' do
      stored_values = { 'CAPTAIN_EMBEDDING_MODEL' => 'openai/text-embedding-3-large' }
      refused = form({ 'CAPTAIN_EMBEDDING_MODEL' => 'google/gemini-embedding-001' }, stored_values: stored_values)

      expect(refused).not_to be_valid
      expect(refused.changes).to be_empty
      expect(refused.errors['CAPTAIN_EMBEDDING_MODEL'].first).to include('rake onelink:embeddings:apply')
    end

    it 'does not matter that the admin ticked a confirmation of the former page: there is none' do
      expect(described_class.instance_method(:initialize).parameters.flatten).not_to include(:confirmed_embedding)
    end

    it 'accepts the model in force, written in full or left empty, and changes nothing' do
      in_force = 'google/gemini-embedding-001'
      builtin = Llm::Models.configured_default_model_for('help_center_search')

      expect(form({ 'CAPTAIN_EMBEDDING_MODEL' => in_force }, stored_values: { 'CAPTAIN_EMBEDDING_MODEL' => in_force })).to be_valid
      expect(form({ 'CAPTAIN_EMBEDDING_MODEL' => '' }, stored_values: { 'CAPTAIN_EMBEDDING_MODEL' => in_force })).to be_valid
      expect(form({ 'CAPTAIN_EMBEDDING_MODEL' => '' }, stored_values: { 'CAPTAIN_EMBEDDING_MODEL' => 'text-embedding-3-large' })).not_to be_valid
      expect(form({ 'CAPTAIN_EMBEDDING_MODEL' => '' }, stored_values: {})).to be_valid
      expect(form({ 'CAPTAIN_EMBEDDING_MODEL' => builtin }, stored_values: {}).changes).to be_empty
    end
  end

  describe 'secrets, numbers and addresses' do
    it 'keeps a secret that is left empty, and records a typed one without ever returning it' do
      result = form('CAPTAIN_OPENROUTER_API_KEY' => '', 'CAPTAIN_FIRECRAWL_API_KEY' => 'fc-typed')

      expect(result.changes.map(&:key)).to eq(['CAPTAIN_FIRECRAWL_API_KEY'])
      expect(result.changes.first).to have_attributes(secret: true)
      expect(result.input.keys).not_to include('CAPTAIN_OPENROUTER_API_KEY', 'CAPTAIN_FIRECRAWL_API_KEY')
    end

    it 'takes a whole number of tokens, with spaces, and refuses anything else in words' do
      expect(changed(form('ACCOUNT_CAPTAIN_TOKENS_LIMIT' => '2 000 000'))).to eq('ACCOUNT_CAPTAIN_TOKENS_LIMIT' => '2000000')
      expect(form('ACCOUNT_CAPTAIN_TOKENS_LIMIT' => '').changes).to be_empty
      expect(form('ACCOUNT_CAPTAIN_TOKENS_LIMIT' => '2 млн').errors['ACCOUNT_CAPTAIN_TOKENS_LIMIT'])
        .to eq(['Введите целое число без букв или оставьте поле пустым.'])
    end

    it 'takes an address that starts with http or https' do
      expect(form('CAPTAIN_OPENROUTER_ENDPOINT' => 'https://openrouter.example/api/v1')).to be_valid
      expect(form('CAPTAIN_OPENROUTER_ENDPOINT' => 'openrouter.example').errors['CAPTAIN_OPENROUTER_ENDPOINT'])
        .to eq(['Адрес должен начинаться с http:// или https://'])
    end

    it 'does not check a number or an address that was not changed, even when it is stored in another shape' do
      stored_values = { 'ACCOUNT_CAPTAIN_TOKENS_LIMIT' => '2 млн', 'CAPTAIN_OPENROUTER_ENDPOINT' => 'openrouter.example' }

      result = form({ 'ACCOUNT_CAPTAIN_TOKENS_LIMIT' => '2 млн', 'CAPTAIN_OPENROUTER_ENDPOINT' => 'openrouter.example ',
                      'CAPTAIN_AUDIO_TRANSCRIPTION_MODEL' => 'openai/gpt-audio-mini' }, stored_values: stored_values)

      expect(result).to be_valid
      expect(changed(result)).to eq('CAPTAIN_AUDIO_TRANSCRIPTION_MODEL' => 'openai/gpt-audio-mini')
    end

    it 'still checks a number or an address that is changed, also when the stored one is in another shape' do
      stored_values = { 'ACCOUNT_CAPTAIN_TOKENS_LIMIT' => '2 млн', 'CAPTAIN_OPENROUTER_ENDPOINT' => 'openrouter.example' }

      result = form({ 'ACCOUNT_CAPTAIN_TOKENS_LIMIT' => '3 млн', 'CAPTAIN_OPENROUTER_ENDPOINT' => 'other.example' }, stored_values: stored_values)

      expect(result.errors).to include('ACCOUNT_CAPTAIN_TOKENS_LIMIT', 'CAPTAIN_OPENROUTER_ENDPOINT')
      expect(result.errors.size).to eq(2)
    end

    it 'ignores what is not a setting of the page' do
      expect(form('FB_APP_ID' => 'x', 'SOMETHING' => 'y').changes).to be_empty
    end
  end

  describe 'a text with line breaks' do
    it 'is the same text whether the line breaks are stored as CRLF (the old page) or sent as CRLF (a browser)' do
      stored_values = { 'CAPTAIN_AI_AGENT_SYSTEM_PROMPT' => "First line.\r\nSecond line." }

      untouched = form({ 'CAPTAIN_AI_AGENT_SYSTEM_PROMPT' => "First line.\r\nSecond line." }, stored_values: stored_values)
      changed_text = form({ 'CAPTAIN_AI_AGENT_SYSTEM_PROMPT' => "First line.\r\nThird line." }, stored_values: stored_values)

      expect(untouched.changes).to be_empty
      expect(changed(changed_text)).to eq('CAPTAIN_AI_AGENT_SYSTEM_PROMPT' => "First line.\nThird line.")
    end
  end

  describe 'the rules of the platform' do
    let(:rule) { { 'id' => 'my_rule', 'type' => 'system', 'group' => 'Strict rules', 'content' => 'Answer in Russian.', 'slot' => nil } }

    it 'records the changed rules, normalized' do
      result = form('CAPTAIN_SYSTEM_PROMPTS' => [rule].to_json)

      expect(changed(result)).to eq('CAPTAIN_SYSTEM_PROMPTS' => [rule])
    end

    it 'does not write the rules that are shown when nothing is stored and nothing was changed' do
      defaults = Captain::Assistant.installation_system_prompt_entries
      result = form({ 'CAPTAIN_SYSTEM_PROMPTS' => defaults.to_json }, stored_values: { 'CAPTAIN_SYSTEM_PROMPTS' => defaults })

      expect(result).to be_valid
      expect(result.changes).to be_empty
    end

    it 'refuses a group that is not in the list, a place that is not in the list, and text that is not rules' do
      expect(form('CAPTAIN_SYSTEM_PROMPTS' => [rule.merge('group' => 'Строгие правила')].to_json).errors['CAPTAIN_SYSTEM_PROMPTS'].first)
        .to eq('Правило 1: группа «Строгие правила» не из списка. Выберите группу из списка.')
      expect(form('CAPTAIN_SYSTEM_PROMPTS' => [rule.merge('slot' => 'assistant_idenity')].to_json).errors['CAPTAIN_SYSTEM_PROMPTS'].first)
        .to eq('Правило 1: место в промпте «assistant_idenity» не из списка. Выберите место из списка.')
      expect(form('CAPTAIN_SYSTEM_PROMPTS' => '{not json').errors['CAPTAIN_SYSTEM_PROMPTS'])
        .to eq(['Правила не удалось прочитать. Обновите страницу и повторите.'])
      expect(form('CAPTAIN_SYSTEM_PROMPTS' => '{"a":1}').errors['CAPTAIN_SYSTEM_PROMPTS']).to be_present
    end

    it 'accepts every group and every place of the lists' do
      SuperAdmin::SystemPromptOptions.group_values.each do |group|
        expect(form('CAPTAIN_SYSTEM_PROMPTS' => [rule.merge('group' => group)].to_json)).to be_valid, group
      end
      SuperAdmin::SystemPromptOptions.slot_values.each do |slot|
        expect(form('CAPTAIN_SYSTEM_PROMPTS' => [rule.merge('slot' => slot)].to_json)).to be_valid, slot
      end
    end

    it 'keeps a group or a place that a saved rule already has, even when the lists do not know it' do
      old_rule = rule.merge('group' => 'Своя группа', 'slot' => 'old_slot')
      result = form({ 'CAPTAIN_SYSTEM_PROMPTS' => [old_rule.merge('content' => 'Changed text.')].to_json },
                    stored_values: { 'CAPTAIN_SYSTEM_PROMPTS' => [old_rule] })

      expect(result).to be_valid
      expect(changed(result)['CAPTAIN_SYSTEM_PROMPTS'].first).to include('group' => 'Своя группа', 'slot' => 'old_slot', 'content' => 'Changed text.')
    end
  end

  describe '#save' do
    it 'writes every change and one entry of the audit log for each' do
      result = form('CAPTAIN_AUDIO_TRANSCRIPTION_MODEL' => 'openai/gpt-audio-mini', 'ACCOUNT_CAPTAIN_TOKENS_LIMIT' => '500')

      expect(result.save(actor: super_admin)).to eq({})
      expect(InstallationConfig.find_by(name: 'CAPTAIN_AUDIO_TRANSCRIPTION_MODEL').value).to eq('openai/gpt-audio-mini')
      expect(InstallationConfig.find_by(name: 'ACCOUNT_CAPTAIN_TOKENS_LIMIT').value).to eq('500')
      audits = Audited::Audit.where(action: SuperAdmin::AppConfigSaver::AUDIT_ACTION).map { |audit| audit.audited_changes['name'] }
      expect(audits).to contain_exactly('CAPTAIN_AUDIO_TRANSCRIPTION_MODEL', 'ACCOUNT_CAPTAIN_TOKENS_LIMIT')
    end

    it 'writes nothing when anything is refused' do
      result = form('CAPTAIN_AUDIO_TRANSCRIPTION_MODEL' => 'openai/gpt-audio-mini', 'CAPTAIN_IMAGE_RECOGNITION_MODEL' => 'vendor/unknown')

      expect(result.save(actor: super_admin).keys).to eq(['CAPTAIN_IMAGE_RECOGNITION_MODEL'])
      expect(InstallationConfig.find_by(name: 'CAPTAIN_AUDIO_TRANSCRIPTION_MODEL')&.value).not_to eq('openai/gpt-audio-mini')
      expect(Audited::Audit.where(action: SuperAdmin::AppConfigSaver::AUDIT_ACTION)).to be_empty
    end

    it 'rolls everything back when the record of a setting refuses a value' do
      result = form('CAPTAIN_AUDIO_TRANSCRIPTION_MODEL' => 'openai/gpt-audio-mini', 'ACCOUNT_CAPTAIN_TOKENS_LIMIT' => '500')
      saver = instance_double(SuperAdmin::AppConfigSaver)
      allow(SuperAdmin::AppConfigSaver).to receive(:new).and_return(saver)
      allow(saver).to receive(:save).with('CAPTAIN_AUDIO_TRANSCRIPTION_MODEL', anything, secret: false) do
        InstallationConfig.find_or_initialize_by(name: 'CAPTAIN_AUDIO_TRANSCRIPTION_MODEL').tap do |config|
          config.value = 'openai/gpt-audio-mini'
          config.save!
        end
        []
      end
      allow(saver).to receive(:save).with('ACCOUNT_CAPTAIN_TOKENS_LIMIT', anything, secret: false).and_return(['is invalid'])

      expect(result.save(actor: super_admin)).to eq('ACCOUNT_CAPTAIN_TOKENS_LIMIT' => ['is invalid'])
      expect(InstallationConfig.find_by(name: 'CAPTAIN_AUDIO_TRANSCRIPTION_MODEL')&.value).not_to eq('openai/gpt-audio-mini')
    end
  end

  describe '#summary' do
    it 'says what changed in words: the names of the models, «встроенная», the number of models of a list' do
      stored_values = { 'CAPTAIN_AUDIO_TRANSCRIPTION_MODEL' => 'openai/gpt-audio-mini',
                        'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST' => '["openai/gpt-6-luna"]' }
      result = form({ 'CAPTAIN_AUDIO_TRANSCRIPTION_MODEL' => '', 'CAPTAIN_IMAGE_RECOGNITION_MODEL' => 'openai/gpt-6-luna',
                      'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST' => %w[openai/gpt-6-luna openai/gpt-5.6-luna], 'CAPTAIN_FIRECRAWL_API_KEY' => 'fc-secret' },
                    stored_values: stored_values)

      expect(result.summary).to eq(
        ['Загрузка сайтов в базу знаний (FireCrawl, необязательно): новое значение сохранено', 'Расшифровка голоса: GPT Audio Mini → встроенная',
         'Распознавание картинок и документов: встроенная → GPT-6 Luna', 'Короткий список моделей: 1 → 2']
      )
      expect(result.summary.join).not_to include('fc-secret')
    end

    it 'says «рекомендуемый (5)» for a blank list, which the platform shows as its recommended models' do
      blank_to_six = form({ 'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST' => %w[openai/gpt-6-luna openai/gpt-5.6-luna] }, stored_values: {})
      six_to_blank = form({ 'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST' => '  ' },
                          stored_values: { 'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST' => '["openai/gpt-6-luna"]' })

      expect(blank_to_six.summary).to eq(['Короткий список моделей: рекомендуемый (5) → 2'])
      expect(six_to_blank.summary).to eq(['Короткий список моделей: 1 → рекомендуемый (5)'])
    end
  end

  describe '#refused_keys' do
    it 'lists the settings that were sent and not saved' do
      result = form('CAPTAIN_AUDIO_TRANSCRIPTION_MODEL' => 'openai/gpt-audio-mini', 'CAPTAIN_IMAGE_RECOGNITION_MODEL' => 'vendor/unknown')

      expect(result.refused_keys).to contain_exactly('CAPTAIN_AUDIO_TRANSCRIPTION_MODEL', 'CAPTAIN_IMAGE_RECOGNITION_MODEL')
    end
  end
end
