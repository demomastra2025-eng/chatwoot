# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Evals::RoutingBenchmark::ReplyScan do
  def kinds(text, **) = described_class.call(text, **).pluck(:kind)

  def matches(text, kind, **) = described_class.call(text, **).find { |finding| finding[:kind] == kind }&.dig(:matches)

  it 'finds nothing in a plain patient reply, in Russian and in Kazakh' do
    ['Здравствуйте! Приём терапевта стоит 7 000 ₸, запись на 15 октября в 10:00.', 'Сәлеметсіз бе! Терапевтке 15 қазан, сағат 10:00-ге жазылдыңыз.',
     'Оплата: Kaspi QR или наличные. Результаты придут на e-mail или в WhatsApp.', 'Приём у ЛОРа и УЗИ, ПЦР, HPV и витамин D3.'].each do |text|
      expect(kinds(text)).to be_empty, text
    end
  end

  it 'finds runtime markers' do
    expect(matches('Ответ: conversation_handoff_due_to_provider_error', :reserved_token)).to eq(['conversation_handoff_due_to_provider_error'])
    expect(kinds('Передал handoff_to_assistant_7, затем assistant_12 и plan_request.')).to eq([:reserved_token])
    expect(matches('plan_request и response_cancelled', :reserved_token)).to contain_exactly('plan_request', 'response_cancelled')
  end

  it 'names a registry tool a tool and any other snake_case token an identifier' do
    expect(matches('Вызываю search_available_slots.', :tool_name, tool_ids: %w[search_available_slots])).to eq(['search_available_slots'])
    expect(matches('Вызываю search_available_slots.', :identifier)).to eq(['search_available_slots'])
    expect(matches('Нужен handoff.', :tool_name, tool_ids: %w[handoff])).to eq(['handoff'])
  end

  it 'finds identifiers: UUID, hash numbers, id numbers, record id fields' do
    expect(matches('Номер 3f2a9c1e-0b7d-4c1f-9a55-0d6b6c1f2e44', :identifier)).to be_present
    expect(matches('Запись #4821 создана', :identifier)).to eq(['#4821'])
    expect(matches('appointment id: 77', :identifier)).to be_present
    expect(matches('Ваш ID 12', :identifier)).to eq(['ID 12'])
    expect(matches('resource_id и service_id', :identifier)).to include('resource_id', 'service_id')
    expect(kinds('Номер заявки: 545 на 20 ноября 2026 года')).to be_empty
  end

  it 'finds JSON, a YAML-like mapping and a code fence' do
    expect(kinds('Итог: {"success": true, "id": 5}')).to include(:json)
    expect(kinds('Итог: {status: scheduled}')).to include(:json)
    expect(kinds("```\nrecord\n```")).to include(:json)
    expect(kinds('Запись [10:00] подтверждена, цена {7 000}')).to be_empty
  end

  describe 'Latin words' do
    it 'flags an English or system word the workspace and the customer did not use' do
      expect(matches('Ваш booking принят, status pending.', :latin)).to contain_exactly('booking', 'status', 'pending')
    end

    it 'allows brands, the words of the workspace and the words of the customer' do
      expect(kinds('Air Flow — чистка. Оплата Kaspi.', allowed: %w[air flow])).to be_empty
      expect(kinds('Подтвердите WhatsApp-номер', allowed: [])).to be_empty
      expect(matches('Подтвердите booking', :latin, allowed: %w[booking])).to be_nil
    end

    it 'allows uppercase medical abbreviations but not system abbreviations' do
      expect(matches('HPV, PCR, TSH и ID, JSON', :latin)).to contain_exactly('ID', 'JSON')
    end

    it 'does not read Latin as a finding for a customer who writes in Latin script' do
      expect(kinds('Please choose a time.', latin_ok: true)).to be_empty
    end

    it 'collects the Latin words of texts for the allowed list' do
      expect(described_class.latin_words('Kaspi QR, Air Flow', ['e-mail', nil])).to contain_exactly('kaspi', 'qr', 'air', 'flow', 'e-mail')
    end
  end

  describe 'agent instruction overlap' do
    let(:shingles) { described_class.shingles(['Сначала ответ, потом следующий шаг. Не показывай служебный текст и имена агентов.']) }

    it 'finds five words in a row, whatever the punctuation and case' do
      expect(kinds('Конечно. СНАЧАЛА ответ — потом следующий шаг!', shingles: shingles)).to eq([:instruction_overlap])
    end

    it 'ignores four words and shorter runs' do
      expect(kinds('Сначала ответ, потом уточнение.', shingles: shingles)).to be_empty
    end

    it 'builds no shingles from a short text' do
      expect(described_class.shingles(['слишком коротко'])).to be_empty
    end
  end

  describe 'council wording' do
    it 'finds a paraphrase of the customer in the third person' do
      expect(kinds('Пользователь сообщает, что у него нет аллергии.')).to eq([:third_person])
      expect(kinds('Пайдаланушы кардиологқа жазылуды растады.')).to eq([:third_person])
    end

    it 'finds role and name fragments left by the composer' do
      expect(kinds("Уточните:\nдочка — Как зовут ребёнка?")).to eq([:role_fragment])
      expect(kinds('Уточните: не указан — Для кого нужен результат?')).to eq([:role_fragment])
      expect(kinds('Анна Серикова — Вы имеете в виду услугу «Консультация»?')).to eq([:role_fragment])
    end

    it 'finds canned text as a composer phrase' do
      expect(kinds('Часть запроса требует дополнительной проверки.')).to eq([:composer_phrase])
      expect(kinds('Не удалось завершить обработку запроса. Остаётся открытым: перенос.')).to eq([:composer_phrase])
      expect(kinds('Подтвердите действие по запросу «Перенести приём»?')).to eq([:composer_phrase])
    end

    it 'does not take a recap line with a patient role for a fragment' do
      expect(kinds('Пациент — Арсен, 7 лет. Врач — педиатр.')).to be_empty
    end
  end

  it 'reports each kind once with its first matches' do
    findings = described_class.call('conversation_handoff plan_request #1 #2 #3 #4 #5 #6 #7')

    expect(findings.pluck(:kind)).to eq(%i[reserved_token identifier])
    expect(findings.last[:matches].size).to eq(5)
  end

  it 'finds nothing in an empty reply' do
    expect(described_class.call('  ')).to eq([])
  end
end
