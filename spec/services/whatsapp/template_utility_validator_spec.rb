# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Whatsapp::TemplateUtilityValidator do
  describe '#call' do
    it 'accepts a valid Russian UTILITY template with sequential variables and short buttons' do
      result = described_class.new(
        body_text: 'Здравствуйте, {{1}}! Вы записаны в «Smile Clinic» на {{2}} в {{3}} к специалисту {{4}}. Подтвердите визит.',
        buttons: [{ type: 'QUICK_REPLY', text: 'Подтверждаю' }, { type: 'QUICK_REPLY', text: 'Перенести' }],
        language: 'ru',
        category: 'UTILITY',
        expected_variables_count: 4
      ).call

      expect(result.valid?).to be(true)
      expect(result.errors).to be_empty
      expect(result.variables).to eq(%w[1 2 3 4])
    end

    it 'accepts a valid Kazakh UTILITY template without hyphenated case endings on variables' do
      result = described_class.new(
        body_text: 'Сәлеметсіз бе, {{1}}! Сіз «Smile Clinic» клиникасына {{2}} күні сағат {{3}} уақытына маман {{4}} қабылдауына жазылдыңыз. Растаңызшы.',
        buttons: [{ type: 'QUICK_REPLY', text: 'Растаймын' }, { type: 'QUICK_REPLY', text: 'Уақытын өзгерту' }],
        language: 'kk',
        category: 'UTILITY',
        expected_variables_count: 4
      ).call

      expect(result.valid?).to be(true)
      expect(result.errors).to be_empty
    end

    it 'rejects Kazakh case endings glued with a hyphen to variables like {{3}}-ке' do
      result = described_class.new(
        body_text: 'Сәлеметсіз бе, {{1}}! Сіз {{2}} күні сағат {{3}}-ке дәрігер {{4}}-ға жазылдыңыз. Келуіңізді растаңыз.',
        buttons: [{ type: 'QUICK_REPLY', text: 'Растаймын' }],
        language: 'kk',
        category: 'UTILITY',
        expected_variables_count: 4
      ).call

      expect(result.valid?).to be(false)
      expect(result.error_codes).to include('hyphen_suffix_after_variable')
    end

    it 'rejects leading and trailing variables (even before final punctuation)' do
      result = described_class.new(
        body_text: '{{1}}, вы записаны на приём {{2}} в {{3}} к врачу {{4}}.',
        buttons: [],
        language: 'ru',
        category: 'UTILITY'
      ).call

      expect(result.valid?).to be(false)
      expect(result.error_codes).to include('leading_variable', 'trailing_variable')
    end

    it 'rejects non-sequential, duplicate, and adjacent variables' do
      result = described_class.new(
        body_text: 'Здравствуйте, {{1}}! Запись на {{1}} {{3}} подтверждена, ждём вас.',
        buttons: [],
        language: 'ru',
        category: 'UTILITY'
      ).call

      expect(result.valid?).to be(false)
      expect(result.error_codes).to include('duplicate_variables', 'non_sequential_variables', 'adjacent_variables')
    end

    it 'rejects promotional stop-words in UTILITY templates' do
      result = described_class.new(
        body_text: 'Здравствуйте, {{1}}! Напоминаем о записи {{2}} и дарим скидку 20% по промокоду на следующий визит.',
        buttons: [],
        language: 'ru',
        category: 'UTILITY'
      ).call

      expect(result.valid?).to be(false)
      expect(result.error_codes).to include('promotional_stop_words')
    end

    it 'rejects Kazakh template when text has no Kazakh script letters' do
      result = described_class.new(
        body_text: 'Здравствуйте, {{1}}! Вы записаны на {{2}} в {{3}}. Пожалуйста, подтвердите визит.',
        buttons: [],
        language: 'kk',
        category: 'UTILITY'
      ).call

      expect(result.valid?).to be(false)
      expect(result.error_codes).to include('missing_kazakh_script')
    end

    it 'rejects buttons longer than 20 characters and body longer than 400 characters' do
      result = described_class.new(
        body_text: "Здравствуйте, {{1}}! #{'Напоминаем о предстоящем визите в нашу клинику. ' * 9}Ждём вас!",
        buttons: [{ type: 'QUICK_REPLY', text: 'Подтверждаю свою запись на завтра' }],
        language: 'ru',
        category: 'UTILITY'
      ).call

      expect(result.valid?).to be(false)
      expect(result.error_codes).to include('body_too_long', 'button_text_too_long')
    end

    it 'serializes semantic tokens like {{contact_name}} to positional {{1}} before validating' do
      result = described_class.new(
        body_text: 'Здравствуйте, {{contact_name}}! Приём {{appointment_date}} в {{appointment_time}} у врача {{specialist_name}}. Подтвердите визит.',
        buttons: [{ type: 'QUICK_REPLY', text: 'Подтверждаю' }],
        language: 'ru',
        category: 'UTILITY',
        expected_variables_count: 4
      ).call

      expect(result.valid?).to be(true)
      expect(result.serialized_body_text).to include('{{1}}', '{{2}}', '{{3}}', '{{4}}')
    end
  end
end
