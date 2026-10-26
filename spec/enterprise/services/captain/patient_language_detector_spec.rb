# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::PatientLanguageDetector do
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:detector) { described_class.new(conversation: conversation, assistant: assistant) }
  let(:model) { 'openai/gpt-6-luna-decisions' }
  let(:decision) { Struct.new(:choice) }
  let(:message_id_key) { described_class::MESSAGE_ID_ATTRIBUTE }

  before do
    allow(Llm::Config).to receive(:model_for).with(feature: :language_detection, account: account, fallback: nil).and_return(model)
  end

  def patient_says(text)
    create(:message, account: account, conversation: conversation, inbox: conversation.inbox, content: text)
  end

  def choose(value)
    allow(Llm::Runtime).to receive(:decide).and_return(decision.new(value))
  end

  def saved(key = described_class::ATTRIBUTE)
    conversation.reload.additional_attributes[key]
  end

  def save_language(language, message_id: nil)
    attributes = conversation.additional_attributes.to_h.merge(described_class::ATTRIBUTE => language)
    attributes[message_id_key] = message_id if message_id
    conversation.update!(additional_attributes: attributes)
  end

  describe 'the decision request' do
    it 'sends one decision with the last 5 patient messages, oldest first, and nothing else from the conversation' do
      21.times { |i| patient_says("Fake patient words #{i}") }
      create(:message, account: account, conversation: conversation, inbox: conversation.inbox, message_type: :outgoing,
                       content: 'Fake staff words')
      create(:message, account: account, conversation: conversation, inbox: conversation.inbox, private: true, content: 'Fake private note')
      choose('kk')

      expect(detector.call).to eq('kk')
      expect(Llm::Runtime).to have_received(:decide).once.with(
        hash_including(
          feature: :language_detection, model: model,
          input: { messages: ['Fake patient words 16', 'Fake patient words 17', 'Fake patient words 18', 'Fake patient words 19',
                              'Fake patient words 20'] },
          options: { decision_criteria: described_class::CRITERIA, decision_instructions: described_class::INSTRUCTIONS }
        )
      )
      expect(saved).to eq('kk')
    end

    it 'sends fewer messages when there are fewer, and previous_language when the conversation has one' do
      save_language('ru')
      patient_says('Это ИИН моего сына')
      choose('ru')

      expect(detector.call).to eq('ru')
      expect(Llm::Runtime).to have_received(:decide).with(
        hash_including(input: { messages: ['Это ИИН моего сына'], previous_language: 'ru' })
      )
    end

    it 'uses a voice transcription and skips an attachment without text' do
      skipped = patient_says('')
      skipped.attachments.create!(account: account, file_type: :image)
      voice = patient_says('')
      voice.attachments.create!(account: account, file_type: :audio, meta: { transcribed_text: 'Fake voice words' })
      choose('en')

      expect(detector.call).to eq('en')
      expect(Llm::Runtime).to have_received(:decide).with(hash_including(input: { messages: ['Fake voice words'] }))
    end

    it 'waits at most 2 seconds for the decision' do
      expect(described_class::TIMEOUT_SECONDS).to eq(2)
    end
  end

  describe 'the rule of the classifier' do
    let(:instructions) { described_class::INSTRUCTIONS }

    it 'is a majority of meaningful words, not the presence of one Kazakh word' do
      expect(instructions).to include('MORE THAN 50%', 'meaningful words', 'at most 5')
      expect(instructions).to include('One Kazakh word or letter in a mostly Russian text does NOT make it Kazakh')
      expect(instructions).not_to match(/any Kazakh word/i)
      expect(described_class::CRITERIA['kk']).to include('More than 50%', 'A single Kazakh word or letter in a mostly Russian text is not enough')
    end

    it 'leaves names, IIN, numbers and medical abbreviations out of the count' do
      expect(instructions).to include('person and place names', 'IIN and document numbers', 'digits', 'УЗИ', 'МРТ', 'ЭКГ')
    end

    it 'keeps the saved language when no language has a majority, and decides unknown otherwise' do
      expect(instructions).to include('choose "unknown": the conversation keeps its previous language')
      expect(described_class::CRITERIA.keys).to eq(%w[ru kk en other unknown])
    end

    it 'keeps within the limits of the decision request' do
      expect(instructions.length).to be <= 8000
      expect(described_class::CRITERIA.values.map(&:length).max).to be <= 2000
    end
  end

  describe 'the language of the conversation' do
    it 'saves the decided language together with the id of the last patient message' do
      patient_says('Fake first')
      last = patient_says('Fake last')
      choose('ru')

      expect(detector.call).to eq('ru')
      expect(saved).to eq('ru')
      expect(saved(message_id_key)).to eq(last.id)
    end

    it 'keeps the saved language for unknown, remembers the message and clears the language for other' do
      patient_says('Fake short reply')
      choose('ru')
      expect(detector.call).to eq('ru')

      last = patient_says('Fake second reply')
      choose('unknown')
      expect(detector.call).to eq('ru')
      expect(saved).to eq('ru')
      expect(saved(message_id_key)).to eq(last.id)

      patient_says('Fake third reply')
      choose('other')
      expect(detector.call).to be_nil
      expect(saved).to be_nil

      patient_says('Fake fourth reply')
      choose('unknown')
      expect(detector.call).to be_nil
    end
  end

  # Suggestion eval 26.10: the decision model answered Russian, six times in six for the same input, for Kazakh turns that had a Russian
  # word in them or came after older Russian messages, and the draft was written in Russian.
  describe 'a turn that reads as Kazakh by its letters and words' do
    def clinic_says(text)
      create(:message, account: account, conversation: conversation, inbox: conversation.inbox, message_type: :outgoing, content: text)
    end

    before { allow(Llm::Runtime).to receive(:decide) }

    it 'is Kazakh with no call of the model, also after older Russian messages, and is saved with the id of the last message' do
      patient_says('Здравствуйте, подскажите стоимость приёма')
      clinic_says('Добрый день! Приём стоит 12 000 ₸.')
      patient_says('Жақсы 21-не жазып қойыңыз')
      last = patient_says('Бағасы қанша болады узи?')

      expect(detector.call).to eq('kk')
      expect(Llm::Runtime).not_to have_received(:decide)
      expect(saved).to eq('kk')
      expect(saved(message_id_key)).to eq(last.id)
      expect(described_class.new(conversation: conversation, assistant: assistant).call).to eq('kk')
    end

    it 'is Kazakh for a sentence with a Russian word in it, with no model configured at all' do
      allow(Llm::Config).to receive(:model_for).with(feature: :language_detection, account: account, fallback: nil).and_return(nil)
      patient_says('Маған врач керек, қанша тұрады')

      expect(detector.call).to eq('kk')
      expect(Llm::Runtime).not_to have_received(:decide)
    end

    it 'follows the turn after the last clinic message: Kazakh words before a clinic reply do not make a Russian turn Kazakh' do
      patient_says('Маған врач керек, қанша тұрады')
      clinic_says('Сәлеметсіз бе! Приём стоит 12 000 ₸.')
      patient_says('Спасибо большое, запишите на пятницу')
      choose('ru')

      expect(detector.call).to eq('ru')
      expect(Llm::Runtime).to have_received(:decide).once
      expect(saved).to eq('ru')
    end

    it 'leaves a Russian text with a Kazakh name or one Kazakh word to the model' do
      patient_says('Запишите Әлия на 10:00, рахмет')
      choose('ru')

      expect(detector.call).to eq('ru')
      expect(Llm::Runtime).to have_received(:decide).once
    end

    it 'takes the one message of a conversation that has no clinic message yet as the turn' do
      patient_says('Кешке 7-8 ге бола ма')
      last = patient_says('Аборт жасатқым келген')

      expect(detector.call).to eq('kk')
      expect(saved(message_id_key)).to eq(last.id)
    end
  end

  describe 'the saved decision' do
    it 'is reused with no call while no new patient message has arrived' do
      patient_says('Fake first')
      choose('kk')
      expect(detector.call).to eq('kk')

      expect(described_class.new(conversation: conversation, assistant: assistant).call).to eq('kk')
      expect(described_class.new(conversation: conversation, assistant: assistant).call).to eq('kk')

      expect(Llm::Runtime).to have_received(:decide).once
    end

    it 'is not reused after a new patient message' do
      patient_says('Fake first')
      choose('kk')
      detector.call
      patient_says('Fake second')
      choose('ru')

      expect(described_class.new(conversation: conversation, assistant: assistant).call).to eq('ru')
      expect(Llm::Runtime).to have_received(:decide).twice
    end

    it 'is not asked again for a message with no text (an image) or a staff message' do
      patient_says('Fake first')
      choose('kk')
      detector.call
      patient_says('').attachments.create!(account: account, file_type: :image)
      create(:message, account: account, conversation: conversation, inbox: conversation.inbox, message_type: :outgoing, content: 'Fake staff')

      expect(described_class.new(conversation: conversation, assistant: assistant).call).to eq('kk')
      expect(Llm::Runtime).to have_received(:decide).once
    end

    it 'counts a voice message whose transcript arrived later as a new message' do
      patient_says('Fake first')
      voice = patient_says('')
      attachment = voice.attachments.create!(account: account, file_type: :audio, meta: {})
      choose('ru')
      expect(detector.call).to eq('ru')
      expect(saved(message_id_key)).not_to eq(voice.id)

      attachment.update!(meta: { transcribed_text: 'Fake kazakh voice words' })
      choose('kk')

      expect(described_class.new(conversation: conversation, assistant: assistant).call).to eq('kk')
      expect(Llm::Runtime).to have_received(:decide).twice
      expect(Llm::Runtime).to have_received(:decide).with(
        hash_including(input: { messages: ['Fake first', 'Fake kazakh voice words'], previous_language: 'ru' })
      )
      expect(saved(message_id_key)).to eq(voice.id)
    end

    it 'does not use a decision saved before the id of the message was kept: it decides once and keeps the id from then on' do
      save_language('ru')
      last = patient_says('Fake first')
      choose('ru')

      detector.call
      described_class.new(conversation: conversation, assistant: assistant).call

      expect(Llm::Runtime).to have_received(:decide).once
      expect(saved(message_id_key)).to eq(last.id)
    end
  end

  describe 'when the decision cannot be made' do
    before { patient_says('Fake private patient text') }

    it 'gives the saved language on a timeout, logs only the error class and decides again next time' do
      save_language('kk')
      stub_const("#{described_class}::TIMEOUT_SECONDS", 0.01)
      allow(Llm::Runtime).to receive(:decide) { sleep(1) }
      allow(Rails.logger).to receive(:warn)

      expect(detector.call).to eq('kk')
      expect(Rails.logger).to have_received(:warn).with('[CAPTAIN][PatientLanguage] unavailable error_class=Timeout::Error')
      expect(saved(message_id_key)).to be_nil
    end

    it 'gives the saved language when the decision raises, and nil when the conversation has none' do
      allow(Llm::Runtime).to receive(:decide).and_raise(Llm::OpenRouterDecisionClient::Error, 'down')
      allow(Rails.logger).to receive(:warn)
      expect(detector.call).to be_nil

      save_language('ru')

      expect(described_class.new(conversation: conversation, assistant: assistant).call).to eq('ru')
      expect(Rails.logger).to have_received(:warn)
        .with('[CAPTAIN][PatientLanguage] unavailable error_class=Llm::OpenRouterDecisionClient::Error').twice
    end

    it 'gives the saved language when no decision model is configured' do
      save_language('en')
      allow(Llm::Config).to receive(:model_for).with(feature: :language_detection, account: account, fallback: nil).and_return(nil)
      allow(Llm::Runtime).to receive(:decide)

      expect(detector.call).to eq('en')
      expect(Llm::Runtime).not_to have_received(:decide)
    end

    it 'gives the saved language for a conversation with no patient text at all' do
      Message.where(conversation_id: conversation.id).delete_all
      save_language('ru')
      allow(Llm::Runtime).to receive(:decide)

      expect(detector.call).to eq('ru')
      expect(Llm::Runtime).not_to have_received(:decide)
    end
  end
end
