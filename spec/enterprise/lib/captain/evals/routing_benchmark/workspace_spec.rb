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

  # The embedding of a FAQ answer is a call to the embedding provider.
  before { allow(Captain::Llm::UpdateEmbeddingJob).to receive(:perform_now) }

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

  describe 'the specialty of a resource' do
    let(:names) do
      { 'terapevt' => 'Терапевт Абдрахманова Сауле', 'uzi_doctor' => 'Кабинет УЗИ (врач Бекова Дана)', 'uzi_room' => 'Кабинет УЗИ (филиал Центр)',
        'mrt' => 'Кабинет МРТ 1,5 Тл (филиал Сайран)', 'lab' => 'Процедурный кабинет (забор анализов)', 'child_lor' => 'Детский ЛОР Ахметова Динара (филиал Сайран)',
        'lor' => 'ЛОР Сергеев Павел', 'dentist' => 'Стоматолог-терапевт Нургалиев Ерик (филиал Сайран)', 'hygienist' => 'Гигиенист Смагулова Лаура (филиал Сайран)' }
    end
    let(:fixture) do
      Captain::Evals::RoutingBenchmark::Fixture.new(
        workspace: {
          agents: [{ name: 'Регистратор', routing_description: 'Запись', instructions: 'Отвечай по-русски.', tool_ids: %w[faq_lookup], model: 'openai/gpt-6-luna' }],
          contacts: [{ key: 'patient', name: 'Дана Нурланова' }],
          resources: names.map { |key, name| { key: key, name: name } }
        },
        dialogues: [{ id: 'case_1', contact: 'patient', turns: [{ customer: 'Здравствуйте', expect: { agent: 'Регистратор', council: false } }] }]
      )
    end

    # A search by specialty finds a resource by what a clinic's staff list calls the position: the name without the person and without the
    # word "Кабинет"; the rooms and the compound positions are named, because their first word alone says nothing.
    it 'is the position in the name of the resource: the first word, or the room or the compound position that the first word cuts' do
      specialties = Scheduling::Resource.where(account_id: workspace.account.id).pluck(:name, :specialty).to_h

      expect(specialties).to eq(
        'Терапевт Абдрахманова Сауле' => 'Терапевт', 'Кабинет УЗИ (врач Бекова Дана)' => 'УЗИ', 'Кабинет УЗИ (филиал Центр)' => 'УЗИ',
        'Кабинет МРТ 1,5 Тл (филиал Сайран)' => 'МРТ', 'Процедурный кабинет (забор анализов)' => 'Процедурный кабинет',
        'Детский ЛОР Ахметова Динара (филиал Сайран)' => 'Детский ЛОР', 'ЛОР Сергеев Павел' => 'ЛОР',
        'Стоматолог-терапевт Нургалиев Ерик (филиал Сайран)' => 'Стоматолог-терапевт', 'Гигиенист Смагулова Лаура (филиал Сайран)' => 'Гигиенист'
      )
    end

    it 'lets the search by specialty of the scheduling tools find the resource (it found nothing in a run that stored no specialty)' do
      search = lambda do |query|
        Scheduling::ResourceSearchService.new(account: workspace.account, query: query, search_by: 'specialty', service_id: nil,
                                              include_inactive: false, limit: 20, offset: 0).perform[:resources].pluck(:name)
      end

      expect(search.call('УЗИ')).to contain_exactly('Кабинет УЗИ (врач Бекова Дана)', 'Кабинет УЗИ (филиал Центр)')
      expect(search.call('Гигиенист')).to eq(['Гигиенист Смагулова Лаура (филиал Сайран)'])
    end
  end

  describe 'the contacts' do
    it 'have a phone number of their own, the patient of a dialogue without a contact included' do
      workspace.conversation_for('id' => 'no_contact')

      phones = Contact.where(account_id: workspace.account.id).order(:id).pluck(:phone_number)

      expect(phones.size).to eq(2)
      expect(phones).to all(match(/\A\+7701\d{7}\z/))
      expect(phones.uniq).to eq(phones)
    end
  end

  describe 'the knowledge base' do
    # Indexing every FAQ of every synthetic clinic costs minutes per dialogue, so a workspace stores the FAQ answers and indexes them
    # only on request (BENCHMARK_FAQ_EMBEDDINGS=1).
    it 'stores every FAQ answer without calling the embedding provider unless indexing was asked for' do
      response = Captain::AssistantResponse.find_by!(account_id: workspace.account.id)

      expect(response).to have_attributes(question: 'Как оплатить?', answer: 'Kaspi QR или наличные.')
      expect(Captain::Llm::UpdateEmbeddingJob).not_to have_received(:perform_now)
    end

    def ask_for_indexing
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('BENCHMARK_FAQ_EMBEDDINGS').and_return('1')
    end

    context 'when indexing was asked for' do
      before { ask_for_indexing }

      # The rows of a dialogue live in a transaction that is never committed, so the callback that indexes a FAQ answer in production
      # does not run, and the FAQ lookup (a vector search) would find nothing.
      it 'indexes every FAQ answer when the workspace is created' do
        response = Captain::AssistantResponse.find_by!(account_id: workspace.account.id)

        expect(Captain::Llm::UpdateEmbeddingJob).to have_received(:perform_now).with(response, 'Как оплатить?: Kaspi QR или наличные.')
      end
    end

    context 'when the embedding provider fails' do
      let(:failure) { Captain::Llm::EmbeddingService::EmbeddingsError.new('overloaded') }
      let(:space) { described_class.new(fixture, model: 'openai/gpt-6-luna', reasoning: 'none') }

      before do
        ask_for_indexing
        allow(space).to receive(:sleep)
      end

      it 'asks again, and goes on when the provider answers' do
        calls = 0
        allow(Captain::Llm::UpdateEmbeddingJob).to receive(:perform_now) { (calls += 1) < 3 ? raise(failure) : nil }

        expect { space.create! }.not_to raise_error
        expect(calls).to eq(3)
        expect(space).to have_received(:sleep).with(1)
        expect(space).to have_received(:sleep).with(2)
      end

      it 'raises the last failure: a FAQ left unindexed would make every lookup of the dialogue find nothing' do
        allow(Captain::Llm::UpdateEmbeddingJob).to receive(:perform_now).and_raise(failure)

        expect { space.create! }.to raise_error(Captain::Llm::EmbeddingService::EmbeddingsError, 'overloaded')
        expect(Captain::Llm::UpdateEmbeddingJob).to have_received(:perform_now).exactly(3).times
      end
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

    it 'holds the text a reply may repeat: knowledge, doctors and services; the names of the seeded patients are kept apart' do
      directory = workspace.directory

      expect(directory.public_texts).to include('Kaspi QR или наличные.', 'Терапевт Абдрахманова Сауле', 'Консультация терапевта')
      expect(directory.public_texts).not_to include('Дана Нурланова')
      expect(directory.contact_names).to eq(['Дана Нурланова'])
    end

    it 'lists everything the workspace wrote, contact names included, for the Latin-word allow-list' do
      expect(workspace.directory.texts).to include('Kaspi QR или наличные.', 'Терапевт Абдрахманова Сауле', 'Дана Нурланова')
    end
  end
end
