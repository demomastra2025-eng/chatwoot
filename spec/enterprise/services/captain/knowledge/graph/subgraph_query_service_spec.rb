# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Knowledge::Graph::SubgraphQueryService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:tool) { Captain::Tools::FaqLookupTool.new(assistant) }
  let(:service) { Captain::Tools::Account::FaqLookupService.new(assistant, user: user) }

  before do
    allow(Captain::Llm::UpdateEmbeddingJob).to receive(:perform_later)
    translation = instance_double(Captain::Llm::TranslateQueryService)
    allow(Captain::Llm::TranslateQueryService).to receive(:new).with(account: account).and_return(translation)
    allow(translation).to receive(:translate) { |query, **| query }
  end

  describe 'Layer 1 & 2: FaqExtractorService + SubgraphQueryService + FaqLookupTool/FaqLookupService' do
    let!(:surgeon_faq) do
      create(
        :captain_assistant_response,
        account: account,
        assistant: assistant,
        question: 'Кто принимает хирургом и проктологом, сколько стоит приём и как записаться?',
        answer: 'RU: Приём взрослых пациентов (от 18 лет) в каб. №217 ведёт хирург и проктолог ' \
                'Кудлай Сергей Павлович (стаж более 11 лет, ежедневно с 09:00 до 15:00). ' \
                'Первичный приём — 10 000 ₸, повторный — 8 000 ₸.',
        status: :approved
      )
    end

    let!(:uzi_price_faq) do
      create(
        :captain_assistant_response,
        account: account,
        assistant: assistant,
        question: 'Кто проводит УЗИ и сколько стоит УЗИ брюшной полости?',
        answer: 'RU: Приём в кабинете УЗИ (каб. №105) ведут врачи Ежбанов Бахыт и Таипова Мехрибан Янаровна. ' \
                'Комплексное УЗИ брюшной полости — 7 000 ₸.',
        status: :approved
      )
    end

    let!(:uzi_prep_faq) do
      create(
        :captain_assistant_response,
        account: account,
        assistant: assistant,
        question: 'Как подготовиться к УЗИ брюшной полости?',
        answer: 'RU: УЗИ органов брюшной полости проводится строго натощак — 6–8 часов без еды и воды перед исследованием.',
        status: :approved
      )
    end

    let!(:eeg_faq) do
      create(
        :captain_assistant_response,
        account: account,
        assistant: assistant,
        question: 'Есть ли у вас ЭЭГ (электроэнцефалография)?',
        answer: 'RU: ЭЭГ (электроэнцефалография) в клинике не проводится.',
        status: :approved
      )
    end

    it 'extracts specialist, specialty, location, age policy, and prices into graph nodes and edges' do
      specialist = account.captain_knowledge_nodes.find_by(node_type: 'specialist', canonical_name: 'Кудлай Сергей Павлович')
      expect(specialist).to be_present
      expect(specialist.attributes_data).to include(
        'available' => true,
        'primary_price_kzt' => 10_000,
        'repeat_price_kzt' => 8_000,
        'cabinet' => 'каб. №217',
        'experience_years' => 11,
        'age_policy' => hash_including('min_age_years' => 18, 'accepts_children' => false)
      )

      related_names = specialist.outgoing_edges.includes(:target_node).map { |e| [e.relation_type, e.target_node.canonical_name] }
      expect(related_names).to include(
        %w[has_specialty хирург],
        %w[has_specialty проктолог],
        ['located_in', 'каб. №217']
      )

      eeg_node = account.captain_knowledge_nodes.find_by(node_type: 'service', canonical_name: 'ЭЭГ (электроэнцефалография)')
      expect(eeg_node).to be_present
      expect(eeg_node.attributes_data['available']).to be(false)
    end

    it 'rescues a query by doctor surname in the answer when vector score is moderate (< 0.70)' do
      scored = Captain::AssistantResponse.select('captain_assistant_responses.*, 0.48 AS neighbor_distance').where(id: surgeon_faq.id)
      allow(Captain::AssistantResponse).to receive(:search).and_return(scored)

      # The full lookup payload with the knowledge graph; the model reads only the compact answer of #perform (question, answer, score).
      payload = tool.send(:lookup_payload, query: 'Сколько стоит приём у Кудлая и принимает ли он детей?')

      expect(payload).to include(
        'result' => 'found',
        'lookup_strategy' => 'graph_faq',
        'total_count' => 1
      )
      expect(payload['matches'].first).to include(
        'id' => surgeon_faq.id,
        'graph_corroboration_passed' => true,
        'relevance_selection' => 'knowledge_graph'
      )
      fact = payload.dig('knowledge_graph', 'verified_facts').find { |f| f['canonical_name'] == 'Кудлай Сергей Павлович' }
      expect(fact['attributes']).to include(
        'primary_price_kzt' => 10_000,
        'repeat_price_kzt' => 8_000,
        'age_policy' => hash_including('accepts_children' => false, 'min_age_years' => 18)
      )
    end

    it 'unifies multi-hop facts (price + preparation) across separate FAQs onto a single Service node' do
      scored = Captain::AssistantResponse.select('captain_assistant_responses.*, 0.15 AS neighbor_distance').where(id: uzi_price_faq.id)
      allow(Captain::AssistantResponse).to receive(:search).and_return(scored)

      payload = JSON.parse(service.execute(query: 'Сколько стоит УЗИ брюшной полости и какая нужна подготовка?'))

      expect(payload['result']).to eq('found')
      expect(payload['matches'].pluck('id')).to include(uzi_price_faq.id, uzi_prep_faq.id)

      uzi_fact = payload.dig('knowledge_graph', 'verified_facts').find { |f| f['canonical_name'] == 'УЗИ брюшной полости' }
      expect(uzi_fact['attributes']).to include(
        'primary_price_kzt' => 7_000,
        'preparation' => include('строго натощак — 6–8 часов без еды и воды')
      )
    end

    it 'cleans up graph evidence when an FAQ is deleted' do
      expect do
        eeg_faq.destroy!
      end.to change {
        account.captain_knowledge_nodes.where(canonical_name: 'ЭЭГ (электроэнцефалография)').count
      }.from(1).to(0)
    end
  end

  describe 'Layer 2 & 3: CatalogSyncService + ConflictDetectorService' do
    let!(:crm_service) do
      create(:scheduling_service, account: account, name: 'ФГДС (гастроскопия)', base_price: 18_000, duration_min: 30, active: true)
    end
    let!(:crm_resource) do
      create(:scheduling_resource, account: account, name: 'Рәтбай Айдын', specialty: 'эндоскопист', active: true)
    end

    before do
      create(:scheduling_service_price, account: account, service: crm_service, resource: crm_resource, price: 18_000)
      Captain::Knowledge::Graph::CatalogSyncService.sync_account!(account)
    end

    it 'syncs live CRM services and specialists and detects price conflicts when an FAQ contradicts the catalog' do
      fgds_node = account.captain_knowledge_nodes.find_by(node_type: 'service', canonical_name: 'ФГДС (гастроскопия)')
      expect(fgds_node).to be_present
      expect(fgds_node.attributes_data['primary_price_kzt']).to eq(18_000)
      expect(fgds_node.conflicts).to be_empty

      create(
        :captain_assistant_response,
        account: account,
        assistant: assistant,
        question: 'Сколько стоит ФГДС?',
        answer: 'RU: Да, стоимость ФГДС составляет 15 000 ₸.',
        status: :approved
      )

      fgds_node.reload
      expect(fgds_node.conflicts).not_to be_empty
      price_conflict = fgds_node.conflicts.find { |c| c['fact'] == 'primary_price_kzt' }
      expect(price_conflict['values']).to contain_exactly(18_000, 15_000)

      report = Captain::Knowledge::Graph::ConflictDetectorService.scan_account(account)
      expect(report).to include(
        hash_including(
          node_id: fgds_node.id,
          canonical_name: 'ФГДС (гастроскопия)'
        )
      )
    end
  end
end
