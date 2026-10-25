# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Routing::CompetenceCard do
  def candidate(id, description, tools = %w[create_appointment], name: "Agent #{id}")
    Captain::Routing::Candidate.new(id: id, name: name, routing_description: description, tool_ids: tools)
  end

  it 'drops links, phone numbers and e-mail addresses and keeps names and prices' do
    text = described_class.text(candidate(1, 'Запись к Кудлаю С.П. (12 000 ₸). Сайт https://sezim.kz, WhatsApp +7 702 444 68 41, mail@sezim.kz.'))

    expect(text).to include('Запись к Кудлаю С.П. (12 000 ₸).')
    expect(text).not_to include('https', 'sezim.kz', '702', '@')
  end

  it 'cuts a long description at a word boundary' do
    text = described_class.text(candidate(1, "#{'слово ' * 400}конец"))

    expect(text.length).to be <= described_class::MAX_LENGTH + 1
    expect(text).to end_with('…')
    expect(text).not_to include('конец')
  end

  it 'marks an agent that cannot book while another agent of the clinic can' do
    surgery = candidate(2, 'ЛОР-операции', %w[faq_lookup])

    expect(described_class.text(surgery, peers: [candidate(1, 'Запись')])).to eq("ЛОР-операции #{described_class::NO_BOOKING_NOTE}")
    expect(described_class.text(surgery, peers: [candidate(3, 'Справки', %w[faq_lookup])])).to eq('ЛОР-операции')
  end

  it 'gives a blank card for a blank description' do
    expect(described_class.text(candidate(1, ' '), peers: [candidate(2, 'x')])).to eq('')
  end

  it 'cuts a long label' do
    expect(described_class.label('Я' * 80).length).to eq(described_class::LABEL_LENGTH)
  end
end
