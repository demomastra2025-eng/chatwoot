# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Scheduling::AiTemplateMasterService do
  let(:account) do
    create(
      :account,
      name: 'Denta Nova',
      settings: { 'client_languages' => %w[ru kk], 'bilingual_templates_enabled' => false }
    )
  end

  before do
    account.enable_features!('scheduling')
  end

  it 'calls Llm::Runtime.chat with openai/gpt-6.1-terra and validates all generated templates across languages' do
    llm_response = double(
      content: {
        templates: [
          {
            scenario_key: 'created_confirmation',
            template_name: 'booking_created_notice',
            language: 'ru',
            body: 'Здравствуйте, {{имя клиента}}! Вы записаны в клинику «Denta Nova» на {{дата записи}} в {{время записи}} к врачу {{специалист}}. Пожалуйста, подтвердите визит.',
            buttons: %w[Подтверждаю Перенести]
          },
          {
            scenario_key: 'created_confirmation',
            template_name: 'booking_created_notice',
            language: 'kk',
            body: 'Сәлеметсіз бе, {{имя клиента}}! Сіз «Denta Nova» клиникасына {{дата записи}} күні сағат {{время записи}} уақытына дәрігер {{специалист}} қабылдауына жазылдыңыз. Сапарыңызды растаңызшы.',
            buttons: ['Растаймын', 'Уақытын өзгерту']
          }
        ]
      }.to_json
    )

    expect(Llm::Runtime).to receive(:chat).twice.with(
      hash_including(
        feature: :editor,
        account: account,
        model: 'openai/gpt-6.1-terra'
      )
    ).and_return(llm_response)

    result = described_class.new(
      account: account,
      languages: %w[ru kk],
      bilingual: false,
      scenario_keys: ['created_confirmation']
    ).call

    expect(result[:model]).to eq('openai/gpt-6.1-terra')
    expect(result[:languages]).to eq(%w[ru kk])
    expect(result[:templates].size).to eq(2)

    ru_tpl = result[:templates].find { |t| t[:language] == 'ru' }
    kk_tpl = result[:templates].find { |t| t[:language] == 'kk' }

    expect(ru_tpl[:name]).to eq('booking_created_notice')
    expect(ru_tpl[:body_text]).to include('Denta Nova', '{{имя клиента}}', '{{дата записи}}', '{{время записи}}', '{{специалист}}')
    expect(ru_tpl[:serialized_body_text]).to include('{{1}}', '{{2}}', '{{3}}', '{{4}}')
    expect(ru_tpl[:validation][:valid]).to be(true)

    expect(kk_tpl[:name]).to eq('booking_created_notice')
    expect(kk_tpl[:body_text]).to include('Denta Nova', '{{имя клиента}}')
    expect(kk_tpl[:validation][:valid]).to be(true)
  end

  it 'repairs hyphenated Kazakh suffixes from AI output and guarantees valid company-based templates' do
    llm_response = double(
      content: {
        templates: [
          {
            scenario_key: 'created_confirmation',
            template_name: 'booking_created_notice',
            language: 'kk',
            body: 'Сәлеметсіз бе, {{1}}! Сіз «Denta Nova» клиникасына {{2}} күні сағат {{3}}-ке дәрігер {{4}} қабылдауына жазылдыңыз. Келетініңізді растаңызшы.',
            buttons: ['Растаймын', 'Уақытын өзгерту']
          }
        ]
      }.to_json
    )
    allow(Llm::Runtime).to receive(:chat).and_return(llm_response)

    result = described_class.new(
      account: account,
      languages: %w[kk],
      bilingual: false,
      scenario_keys: ['created_confirmation']
    ).call

    kk_tpl = result[:templates].first
    expect(kk_tpl[:serialized_body_text]).not_to match(/\}\}\s*-[\p{L}]+/u)
    expect(kk_tpl[:validation][:valid]).to be(true)
  end

  it 'generates bilingual single-message templates when bilingual is true' do
    allow(Llm::Runtime).to receive(:chat).and_return(double(content: '{}'))

    result = described_class.new(
      account: account,
      languages: %w[kk ru],
      bilingual: true
    ).call

    expect(result[:bilingual]).to be(true)
    expect(result[:templates].size).to eq(6)
    expect(result[:drafts].size).to eq(6)
    expect(result[:templates]).to all(satisfy { |t| t[:validation][:valid] == true && t[:bilingual] == true && t[:preset_key].present? })
  end

  it 'succeeds in bilingual mode when account settings has no client_languages key yet' do
    blank_account = create(:account, name: 'Almaty Med', settings: {})
    blank_account.enable_features!('scheduling')
    allow(Llm::Runtime).to receive(:chat).and_return(double(content: '{}'))

    result = described_class.new(
      account: blank_account,
      language: 'ru',
      bilingual: true
    ).call

    expect(result[:bilingual]).to be(true)
    expect(result[:templates].size).to eq(6)
    expect(result[:templates]).to all(satisfy { |t| t[:validation][:valid] == true })
  end
end
