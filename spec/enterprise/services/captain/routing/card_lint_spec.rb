# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Routing::CardLint do
  def candidate(id, description, tools = %w[create_appointment])
    Captain::Routing::Candidate.new(id: id, name: "Agent #{id}", routing_description: description, tool_ids: tools)
  end

  def codes(findings) = findings.map { |finding| [finding.severity, finding.code, finding.assistant_ids] }

  it 'finds blank cards, coordinator wording, shared doctor names and the owner of general questions' do
    findings = described_class.call([
                                      candidate(85, 'Главный координатор. Общие вопросы о клинике. Терапевт Асланов М.И.'),
                                      candidate(113, 'УЗИ у Асланова М.И. и Асланов М.И. с 3 лет'),
                                      candidate(114, '')
                                    ])

    expect(codes(findings)).to include(['error', 'blank_card', [114]], ['error', 'handoff_wording', [85]],
                                       ['warning', 'shared_name', [85, 113]])
    expect(codes(findings).map(&:second)).not_to include('general_owner')
  end

  it 'warns when no card or several cards cover general questions' do
    none = described_class.call([candidate(1, 'УЗИ'), candidate(2, 'Анализы')])
    several = described_class.call([candidate(1, 'Общие вопросы о центре'), candidate(2, 'Общие вопросы о филиале')])

    expect(codes(none)).to include(['warning', 'general_owner', []])
    expect(codes(several)).to include(['warning', 'general_owner', [1, 2]])
  end

  it 'does not take a staff handoff step for a transfer, but finds a transfer to another agent' do
    staff = 'Передай диалог старшему администратору через handoff.'
    transfer = 'При записи к врачу переведи диалог агенту «Администратор Intermedical» (transfer_to_agent_85).'

    expect(described_class.forbidden_words(staff)).to be_empty
    expect(described_class.forbidden_words(transfer)).to include('transfer_to_agent_85')
    expect(described_class.forbidden_words('Ты — главный ИИ-администратор клиники')).not_to be_empty
  end

  it 'checks nothing for a clinic with one agent' do
    expect(described_class.call([candidate(1, '')])).to eq([])
  end
end
