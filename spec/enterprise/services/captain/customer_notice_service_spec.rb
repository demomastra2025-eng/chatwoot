require 'rails_helper'

RSpec.describe Captain::CustomerNoticeService do
  let(:account) { create(:account, locale: 'ru') }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, inbox: inbox, account: account, status: :pending) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:kind) { :handoff }
  let(:reason_label) { nil }
  let(:service) { described_class.new(conversation: conversation, assistant: assistant, kind: kind, reason_label: reason_label) }
  let(:handoff_key) { 'handoff_message' }
  let(:answer) { 'Сотрудник продолжит диалог с вами.' }

  def customer_says(content)
    create(:message, conversation: conversation, account: account, inbox: inbox, message_type: :incoming, content: content)
  end

  # The notice model answers with `text`; the arguments of the request are collected in the returned hash.
  def stub_notice_answer(text)
    request = {}
    stub_notice_model
    allow(Llm::Runtime).to receive(:chat).with(hash_including(feature: :customer_notice)) do |**attributes|
      request.merge!(attributes)
      Struct.new(:content).new(text)
    end
    request
  end

  def user_data(request)
    JSON.parse(request[:messages].last[:content])
  end

  describe 'a notice that is switched off or has no text' do
    it 'writes nothing for a disabled handoff message, even with a text and in AI mode' do
      configure_notice(account, handoff_key, enabled: false, mode: 'generated', text: 'Configured text')
      expect(Llm::Runtime).not_to receive(:chat)

      expect(service.text).to be_nil
      expect(service.source).to be_nil
    end

    it 'writes nothing for a disabled closing message' do
      configure_notice(account, 'resolution_message', enabled: false, text: 'Configured text')

      expect(described_class.new(conversation: conversation, assistant: assistant, kind: :resolution).text).to be_nil
    end

    it 'has no built-in wording for a fixed message without text' do
      configure_notice(account, handoff_key, enabled: true, mode: 'fixed', text: '  ')

      expect(service.text).to be_nil
      expect(service.source).to be_nil
    end
  end

  describe 'a fixed message' do
    it 'is the owner text, rendered with the runtime text rendering, and never calls the model' do
      configure_notice(account, handoff_key, mode: 'fixed', text: 'Сейчас подключится сотрудник.')
      allow(assistant).to receive(:render_runtime_text).and_call_original
      expect(Llm::Runtime).not_to receive(:chat)

      expect(service.text).to eq('Сейчас подключится сотрудник.')
      expect(service.source).to eq('fixed')
      expect(assistant).to have_received(:render_runtime_text).with('Сейчас подключится сотрудник.', conversation: conversation)
    end

    it 'writes a $ field as the value alone, so the customer never reads a label or a field id' do
      conversation.contact.update!(name: 'Айгерим', phone_number: nil)
      text = '[$Имя](field://contact.name), сотрудник скоро подключится. Ваш номер: [$Телефон](field://contact.phone_number).'
      configure_notice(account, handoff_key, mode: 'fixed', text: text)

      expect(service.text).to eq('Айгерим, сотрудник скоро подключится. Ваш номер: .')
      expect(service.text).not_to include('contact.', '(', 'не указано', 'not specified')
    end
  end

  describe 'an AI-written message' do
    before do
      configure_notice(account, handoff_key, mode: 'generated', text: 'Запасной текст', instruction: 'Коротко и тепло.')
      customer_says('Хочу записаться к врачу')
    end

    it 'is written by a separate model call with no tools, no reasoning and a short output' do
      allow(Llm::RuntimePolicy).to receive(:no_reasoning_params).and_return({ enabled: false })
      request = stub_notice_answer(answer)

      expect(service.text).to eq(answer)
      expect(service.source).to eq('generated')
      expect(request).to include(feature: :customer_notice, model: 'openai/gpt-6-luna', max_tokens: 300, reasoning: { enabled: false })
      expect(request).not_to have_key(:tools)
      expect(request[:messages].first).to include(role: 'system')
    end

    it 'sends the kind, the language, the last public customer messages, the reason label and the instruction as data' do
      customer_says('Мне нужен администратор')
      create(:message, conversation: conversation, account: account, inbox: inbox, message_type: :outgoing, content: 'Ответ сотрудника')
      create(:message, conversation: conversation, account: account, inbox: inbox, message_type: :outgoing, private: true,
                       content: 'Внутренняя заметка')
      request = stub_notice_answer(answer)

      described_class.new(conversation: conversation, assistant: assistant, kind: :handoff, reason_label: 'Нужен человек').text

      expect(user_data(request)).to eq(
        'kind' => 'handoff',
        'customer_messages' => ['Хочу записаться к врачу', 'Мне нужен администратор'],
        'reason_label' => 'Нужен человек',
        'style_guide' => 'Коротко и тепло.'
      )
    end

    it 'uses the persisted decision for a Kazakh notice' do
      conversation.update!(additional_attributes: conversation.additional_attributes.merge('captain_patient_language' => 'kk'))
      request = stub_notice_answer('Қызметкер сізбен әңгімені жалғастырады.')

      expect(service.text).to eq('Қызметкер сізбен әңгімені жалғастырады.')
      expect(user_data(request)['customer_language']).to eq('kk')
    end

    it 'uses the closing message settings for a closing notice' do
      configure_notice(account, 'resolution_message', mode: 'generated', instruction: 'Поблагодарите клиента.')
      request = stub_notice_answer('Диалог закрыт, спасибо за обращение.')

      notice = described_class.new(conversation: conversation, assistant: assistant, kind: :resolution)

      expect(notice.text).to eq('Диалог закрыт, спасибо за обращение.')
      expect(user_data(request)).to include('kind' => 'resolution', 'style_guide' => 'Поблагодарите клиента.')
    end

    it 'runs the model once however often the text is asked for' do
      stub_notice_model
      expect(Llm::Runtime).to receive(:chat).once.and_return(Struct.new(:content).new(answer))

      service.prepare
      service.text
      service.text
    end

    it 'is not rendered as a template' do
      stub_notice_answer(answer)
      allow(assistant).to receive(:render_runtime_text).and_call_original

      service.text

      expect(assistant).not_to have_received(:render_runtime_text)
    end
  end

  describe 'the language of an AI-written message' do
    before { configure_notice(account, handoff_key, mode: 'generated', text: '') }

    it 'sends no language hint when the decision has none' do
      customer_says('Fake patient words')
      request = stub_notice_answer(answer)

      service.text

      expect(user_data(request)).not_to have_key('customer_language')
    end

    it 'sends an English hint from the conversation decision' do
      customer_says('Fake patient words')
      conversation.update!(additional_attributes: conversation.additional_attributes.merge('captain_patient_language' => 'en'))
      request = stub_notice_answer('A staff member will continue the conversation.')

      service.text

      expect(user_data(request)['customer_language']).to eq('en')
    end
  end

  describe 'a notice that must not be generated' do
    before { configure_notice(account, handoff_key, mode: 'generated', text: 'Запасной текст', instruction: 'Коротко.') }

    it 'goes straight to the fixed text without a model call when generation is not allowed' do
      stub_notice_model
      notice = described_class.new(conversation: conversation, assistant: assistant, kind: kind, generate: false)

      expect(notice.text).to eq('Запасной текст')
      expect(notice.source).to eq('fallback_fixed')
      expect(Llm::Runtime).not_to have_received(:chat).with(hash_including(feature: :customer_notice))
    end

    it 'goes straight to the neutral sentence when there is no fixed text' do
      configure_notice(account, handoff_key, mode: 'generated', text: '')
      stub_notice_model

      notice = described_class.new(conversation: conversation, assistant: assistant, kind: kind, generate: false)

      expect(notice.text).to eq('Сотрудник продолжит диалог с вами.')
      expect(notice.source).to eq('fallback_builtin')
      expect(Llm::Runtime).not_to have_received(:chat).with(hash_including(feature: :customer_notice))
    end

    it 'still writes nothing for a disabled message' do
      configure_notice(account, handoff_key, enabled: false, mode: 'generated', text: 'Запасной текст')

      expect(described_class.new(conversation: conversation, assistant: assistant, kind: kind, generate: false).text).to be_nil
    end
  end

  describe 'when the AI-written message cannot be used' do
    before { customer_says('Хочу записаться к врачу') }

    it 'falls back to the fixed text when there is one' do
      configure_notice(account, handoff_key, mode: 'generated', text: 'Запасной текст')
      stub_notice_model(error: StandardError.new('boom'))

      expect(service.text).to eq('Запасной текст')
      expect(service.source).to eq('fallback_fixed')
    end

    it 'falls back to a neutral sentence in Russian when there is no fixed text' do
      configure_notice(account, handoff_key, mode: 'generated', text: '')
      stub_notice_model(error: StandardError.new('boom'))

      expect(service.text).to eq('Сотрудник продолжит диалог с вами.')
      expect(service.source).to eq('fallback_builtin')
    end

    it 'falls back to a neutral sentence in the decided Kazakh language' do
      conversation.update!(additional_attributes: conversation.additional_attributes.to_h.merge('captain_patient_language' => 'kk'))
      configure_notice(account, handoff_key, mode: 'generated', text: '')
      stub_notice_model(error: StandardError.new('boom'))

      expect(service.text).to eq('Қызметкер сізбен әңгімені жалғастырады.')
    end

    it 'falls back to a neutral sentence in the decided English language' do
      conversation.update!(additional_attributes: conversation.additional_attributes.to_h.merge('captain_patient_language' => 'en'))
      configure_notice(account, handoff_key, mode: 'generated', text: '')
      stub_notice_model(error: StandardError.new('boom'))

      expect(service.text).to eq('A staff member will continue the conversation with you.')
    end

    it 'has a neutral closing sentence too' do
      configure_notice(account, 'resolution_message', mode: 'generated', text: '')
      stub_notice_model(error: StandardError.new('boom'))

      expect(described_class.new(conversation: conversation, assistant: assistant, kind: :resolution).text)
        .to eq('Диалог закрыт. Если появятся вопросы, напишите нам снова.')
    end

    it 'falls back when the model is slow' do
      configure_notice(account, handoff_key, mode: 'generated', text: 'Запасной текст')
      stub_notice_model(error: Timeout::Error.new('slow'))

      expect(service.text).to eq('Запасной текст')
    end

    it 'falls back when no model is available' do
      configure_notice(account, handoff_key, mode: 'generated', text: '')
      allow(Llm::Config).to receive(:model_for).and_call_original
      allow(Llm::Config).to receive(:model_for).with(feature: 'customer_notice', account: anything, fallback: nil).and_return(nil)
      expect(Llm::Runtime).not_to receive(:chat)

      expect(service.text).to eq('Сотрудник продолжит диалог с вами.')
    end

    [['an empty answer', ''], ['a blank answer', " \n "], ['an answer without text', nil]].each do |label, content|
      it "falls back to the fixed text for #{label}" do
        configure_notice(account, handoff_key, mode: 'generated', text: 'Запасной текст')
        stub_notice_answer(content)

        expect(service.text).to eq('Запасной текст')
        expect(service.source).to eq('fallback_fixed')
      end
    end

    it 'falls back to the neutral sentence for an empty answer when there is no fixed text' do
      configure_notice(account, handoff_key, mode: 'generated', text: '')
      stub_notice_answer('')

      expect(service.text).to eq('Сотрудник продолжит диалог с вами.')
      expect(service.source).to eq('fallback_builtin')
    end
  end

  # Owner rule: the text the model wrote is never judged by code (no word lists, patterns or character checks).
  describe 'the text the model wrote' do
    before { configure_notice(account, handoff_key, mode: 'generated', text: 'Запасной текст') }

    [
      'Сотрудник клиники продолжит диалог с вами.',
      'Благодарим за обращение. Диалог закрыт, если появятся вопросы, напишите нам.',
      'Қызметкер сізбен әңгімені жалғастырады.',
      'Әңгіме жабылды. Сұрағыңыз болса, бізге қайта жазыңыз.',
      'Наш специалист свяжется с вами через мессенджер.',
      'Пишите в Telegram или звоните +7 701 000 00 00, сотрудник ответит.',
      'Сотрудник ответит в течение 5 минут. Подробности на https://example.com',
      'Администратор скоро свяжется с вами.'
    ].each do |text|
      it "is sent as returned: #{text}" do
        stub_notice_answer(text)

        expect(service.text).to eq(text)
        expect(service.source).to eq('generated')
      end
    end

    it 'is only trimmed, nothing else is removed from it' do
      stub_notice_answer(%(\n  "#{answer}"  \n))

      expect(service.text).to eq(%("#{answer}"))
    end

    it 'is cut at the last sentence end when it is longer than the limit' do
      sentence = 'Сотрудник продолжит диалог с вами.'
      stub_notice_answer(([sentence] * 20).join(' '))

      expect(service.text).to eq(([sentence] * 14).join(' '))
      expect(service.text.length).to be <= described_class::MAX_TEXT_LENGTH
      expect(service.source).to eq('generated')
    end

    it 'is cut at a word when it is longer than the limit and has no sentence end' do
      stub_notice_answer(Array.new(200) { 'слово' }.join(' '))

      expect(service.text.length).to be <= described_class::MAX_TEXT_LENGTH
      expect(service.text).to match(/\Aслово( слово)+\z/)
    end
  end

  describe 'events' do
    let(:events) { [] }
    let(:subscriber) do
      ActiveSupport::Notifications.subscribe(/\Acaptain\.customer_notice\./) do |name, _start, _finish, _id, payload|
        events << [name, payload]
      end
    end

    before do
      subscriber
      customer_says('Здравствуйте')
    end

    after { ActiveSupport::Notifications.unsubscribe(subscriber) }

    it 'publishes ids and the kind when the notice is generated' do
      configure_notice(account, handoff_key, mode: 'generated', text: 'Запасной текст', instruction: 'Секретная инструкция')
      stub_notice_answer(answer)

      service.text

      name, payload = events.first
      expect(name).to eq('captain.customer_notice.generated')
      expect(payload).to include('account_id' => account.id, 'assistant_id' => assistant.id, 'conversation_id' => conversation.id,
                                 'kind' => 'handoff')
      expect(payload.to_s).not_to include('Секретная инструкция', 'Здравствуйте', answer)
    end

    it 'publishes ids, the kind and a reason code when the notice falls back' do
      configure_notice(account, handoff_key, mode: 'generated', text: 'Запасной текст')
      stub_notice_model(error: Timeout::Error.new('slow'))

      service.text

      name, payload = events.first
      expect(name).to eq('captain.customer_notice.fallback')
      expect(payload).to include('account_id' => account.id, 'conversation_id' => conversation.id, 'kind' => 'handoff', 'reason' => 'timeout')
      expect(payload.to_s).not_to include('Запасной текст', 'Здравствуйте')
    end

    it 'publishes nothing for a fixed message' do
      configure_notice(account, handoff_key, mode: 'fixed', text: 'Текст')

      service.text

      expect(events).to be_empty
    end
  end

  describe 'the model slot' do
    it 'is declared like the other platform-managed model slots, with Luna 6 as the default' do
      expect(Llm::Config::INSTALLATION_MANAGED_MODEL_CONFIGS).to include('customer_notice' => 'CAPTAIN_CUSTOMER_NOTICE_MODEL')
      expect(Llm::Models.configured_default_model_for('customer_notice')).to eq('openai/gpt-6-luna')
      expect(Llm::Models.feature_keys).to include('customer_notice')
      expect(Llm::FeatureProfile.for('customer_notice', account: account)).to have_attributes(reasoning_policy: 'disabled')
    end

    it 'is validated and editable by the platform admin like the other slots' do
      expect(Llm::InstallationModelConfig.manages?('CAPTAIN_CUSTOMER_NOTICE_MODEL')).to be(true)
      expect(Llm::InstallationModelConfig.normalize('CAPTAIN_CUSTOMER_NOTICE_MODEL', 'gpt-5-mini')).to be_valid
      expect(Llm::InstallationModelConfig.normalize('CAPTAIN_CUSTOMER_NOTICE_MODEL', '')).to be_valid
    end

    it 'is offered by the super admin captain settings' do
      expect(SuperAdmin::AppConfigsController::CAPTAIN_CONFIG_KEYS).to include('CAPTAIN_CUSTOMER_NOTICE_MODEL')
    end
  end

  it 'rejects an unknown kind' do
    expect { described_class.new(conversation: conversation, assistant: assistant, kind: :welcome) }
      .to raise_error(ArgumentError, /Unknown notice kind/)
  end
end
