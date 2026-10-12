# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Evals::RoutingBenchmark::Workspace do
  let(:fixture) do
    Captain::Evals::RoutingBenchmark::Fixture.new(
      workspace: {
        agents: [{ name: 'Регистратор', routing_description: 'Запись', instructions: 'Отвечай по-русски.',
                   tool_ids: %w[faq_lookup create_appointment handoff], model: 'openai/gpt-6-luna' }],
        knowledge: [{ question: 'Как оплатить?', answer: 'Kaspi QR или наличные.' }],
        contacts: [{ key: 'patient', name: 'Дана Нурланова' }],
        resources: [{ key: 'doctor_a', name: 'Терапевт Абдрахманова Сауле' }, { key: 'doctor_b', name: 'Кардиолог Омаров Тимур' }],
        services: [{ key: 'consult', name: 'Консультация терапевта', duration_min: 30, base_price: 7000 }]
      },
      dialogues: [{ id: 'case_1', contact: 'patient',
                    turns: [{ customer: 'Здравствуйте', expect: { agent: 'Регистратор', council: false } }] }]
    )
  end
  let(:workspace) { described_class.new(fixture, model: 'openai/gpt-6-luna', reasoning: 'none').create! }

  describe '#create!' do
    it 'turns audit_logs on for the synthetic account, so executed tools leave their arguments and results' do
      expect(workspace.account.feature_enabled?('audit_logs')).to be(true)
      expect(described_class::FEATURES).not_to include('audit_logs')
    end

    it 'writes no tool audit row while it sets the account up' do
      expect(Captain::Evals::RoutingBenchmark::ToolTrace.cursor(workspace.account)).to eq(0)
    end

    it 'makes a public tool that really runs leave an audit row with its arguments, which the benchmark reads back' do
      allow(Captain::ToolPolicy).to receive(:execution_allowed?).and_return(true)
      conversation = workspace.conversation_for(fixture.dialogues.first)
      run_context = instance_double(
        Captain::Runtime::RunContext,
        context: { state: { conversation: { id: conversation.id }, captain_control_generation: 0 }, current_agent: 'Регистратор' }, usage: {}
      )
      cursor = Captain::Evals::RoutingBenchmark::ToolTrace.cursor(workspace.account)

      Captain::Tools::HandoffTool.new(workspace.agents.values.first).execute(Captain::Runtime::ToolContext.new(run_context: run_context),
                                                                             reason: 'Needs a human')

      calls = Captain::Evals::RoutingBenchmark::ToolTrace.build(
        events: [], audits: Captain::Evals::RoutingBenchmark::ToolTrace.audits_after(workspace.account, cursor)
      )
      expect(calls).to contain_exactly(a_hash_including(tool: 'handoff', audited: true, agent: 'Регистратор',
                                                        arguments: { 'reason' => 'Needs a human' }))
    end
  end

  describe '#directory' do
    it 'maps the fixture keys to the created records and back' do
      directory = workspace.directory
      doctor = Scheduling::Resource.find_by!(account_id: workspace.account.id, name: 'Кардиолог Омаров Тимур')

      expect(directory.resource_id('doctor_b')).to eq(doctor.id)
      expect(directory.resource_key(doctor.id)).to eq('doctor_b')
      expect(directory.service_key(directory.service_id('consult'))).to eq('consult')
      expect(directory.contact_key(directory.contact_id('patient'))).to eq('patient')
      expect(directory.resources.pluck(:key)).to contain_exactly('doctor_a', 'doctor_b')
    end

    it 'says which key it does not know' do
      expect { workspace.directory.resource_id('nobody') }.to raise_error(ArgumentError, /Unknown resource key.*nobody/)
    end

    it 'holds the text a reply may repeat: knowledge, doctors, services and contacts' do
      expect(workspace.directory.texts).to include('Kaspi QR или наличные.', 'Терапевт Абдрахманова Сауле', 'Консультация терапевта',
                                                   'Дана Нурланова')
    end
  end
end
